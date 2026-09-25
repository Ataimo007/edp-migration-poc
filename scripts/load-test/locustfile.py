"""Load-tests the APIs scripts/seed.sh just created, using the real
developer keys it issued — no separate setup, no hand-copied credentials.

Reads one .seed-state/run-*.yaml|json file (scripts/seed.sh's own output:
every developer, the key(s) issued to them, and — per an earlier addition —
which seeded API each key is valid against, plus that API's full,
externally-callable URL) and assigns one credential per simulated user in
a fixed round-robin order — with -u >= the number of usable keys (run.sh
defaults to exactly that, via /credential-count below), every seeded key
gets its own worker and every seeded API actually gets called, not just
whichever ones a random sample happened to land on. Each simulated user
repeatedly calls its own key's one API at httpbin's /anything endpoint,
authenticated exactly the way that API's auth_type actually requires —
the same mix of auth types a real migrated tenant would have, not a
single hardcoded happy path.

Runs as docker-compose.yml's own "locust" service — opt-in via
`./up.sh --load-test` (never part of the always-up stack, since this
generates real, continuous traffic against the Gateway the moment it
starts — see entrypoint.sh, which waits for scripts/seed.sh to actually
produce a .seed-state/ file before starting Locust for real), serving its
persistent web UI at http://localhost:${LOCUST_HOST_PORT:-8089}. See this
directory's own README.md for the full walkthrough, including a scripted
headless alternative (run.sh) to the web UI.

SEED_STATE_FILE defaults to the most recently modified
.seed-state/run-*.yaml|json file (relative to the current working
directory) if not set — the common case of "load-test whatever was seeded
most recently". LOAD_TEST_RPS (per worker, not aggregate) defaults to
0.5 — see PACING_SECONDS below for exactly why — overridable via
`./up.sh --load-test-rps N`.
"""

from __future__ import annotations

import glob
import itertools
import os
import sys
from urllib.parse import urlsplit

import yaml
from locust import HttpUser, constant_pacing, events, task

# Target requests per second *per worker* (one worker per developer key —
# this is never an aggregate figure), overridable via docker-compose.yml's
# own LOAD_TEST_RPS (in turn set by ./up.sh's --load-test-rps). Defaults
# to 0.5 — the same pace a random 1-3s think time averaged out to before
# this was made explicit/configurable. That pace alone once exhausted a
# seeded Policy's daily quota in about half an hour, but the fix for that
# lives on the *quota* side now (scripts/seed.sh's own --quota-min, high
# enough by default to absorb a full day at this same rate) rather than
# throttling every load-test run down regardless of how much quota is
# actually available — a fixed operator preference, not a rediscovery.
LOAD_TEST_RPS = float(os.environ.get("LOAD_TEST_RPS", "0.5"))
if LOAD_TEST_RPS <= 0:
    sys.exit(f"LOAD_TEST_RPS must be a positive number, got {LOAD_TEST_RPS!r}")
PACING_SECONDS = 1.0 / LOAD_TEST_RPS

# Auth types this load runner actually knows how to authenticate a request
# with. hmac/jwt/oauth/openid/mutualTLS each need real request-time work
# (a signed request, a minted/refreshed token, a client TLS handshake) that
# a flat (raw_key, password) pair from the seed-state file alone can't
# drive generically — a key issued for one of those is skipped (with a
# one-time warning naming it, not a silent drop) rather than sent as a
# broken, guaranteed-to-fail request. Contributions adding one of these
# are welcome: each just needs its own branch in request_kwargs_for below.
SUPPORTED_AUTH_TYPES = {"authToken", "basic"}


def _find_seed_state_file() -> str:
    explicit = os.environ.get("SEED_STATE_FILE")
    if explicit:
        return explicit
    candidates = glob.glob(".seed-state/run-*.yaml") + glob.glob(".seed-state/run-*.yml") + glob.glob(".seed-state/run-*.json")
    if not candidates:
        sys.exit(
            "no SEED_STATE_FILE set and no .seed-state/run-*.yaml|json found in the current "
            "directory — run this from poc-environment/, or set SEED_STATE_FILE explicitly "
            "(see this file's own module docstring)."
        )
    return max(candidates, key=os.path.getmtime)


def _load_credentials(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as f:
        # yaml.safe_load reads seed.sh's default YAML output; JSON is a
        # strict subset of YAML, so the same call handles --state-format
        # json output too, with no separate branch needed.
        state = yaml.safe_load(f) or {}

    apis_by_id = {api["id"]: api for api in state.get("apis", [])}
    credentials: list[dict] = []
    unsupported_seen: set[str] = set()

    for dev in state.get("developers", []):
        for key in dev.get("keys", []):
            api = apis_by_id.get(key.get("api_id"))
            if api is None:
                continue  # a key referencing an api_id this file doesn't have an api entry for — an older seed-state predating that field, or a manually-edited file
            auth_type = api["auth_type"]
            if auth_type not in SUPPORTED_AUTH_TYPES:
                unsupported_seen.add(auth_type)
                continue
            credentials.append(
                {
                    "developer_email": dev["email"],
                    "auth_type": auth_type,
                    "api_name": api["name"],
                    # internal_url (tyk-gateway:8080/..., reachable only
                    # from another container on the "tyk" docker network —
                    # see docker-compose.yml's own "locust" service, the
                    # only way this file is meant to run) is preferred;
                    # url (the host-published-port address) is only a
                    # fallback for an older seed-state file recorded
                    # before internal_url existed.
                    "url": api.get("internal_url") or api["url"],
                    "raw_key": key["raw_key"],
                    "password": key.get("password", ""),
                }
            )

    for auth_type in sorted(unsupported_seen):
        print(
            f"[load-test] skipping every {auth_type!r} key — no request-signing support for "
            f"that auth type yet (see SUPPORTED_AUTH_TYPES in {__file__})",
            file=sys.stderr,
        )
    return credentials


SEED_STATE_PATH = _find_seed_state_file()
CREDENTIALS = _load_credentials(SEED_STATE_PATH)

# Locust's HttpUser refuses to even instantiate without a non-empty `host`
# (checked in User.__init__, before on_start ever runs) — purely cosmetic
# here, since every request below passes its own credential's full,
# absolute URL (which requests/Locust use as-is, ignoring self.host
# entirely), but still has to be *something* real for that guard to pass.
_DEFAULT_HOST = urlsplit(CREDENTIALS[0]["url"]).scheme + "://" + urlsplit(CREDENTIALS[0]["url"]).netloc if CREDENTIALS else ""

# One credential per new simulated user, in a fixed round-robin order —
# not random.choice(CREDENTIALS). Confirmed live this was a real gap:
# with a small --headless -u count relative to a much larger credential
# pool, random selection left most seeded APIs never called at all for
# the length of a short run, purely by chance, which looked like "only
# one API is being called" even though every key was equally likely to
# be picked in principle. Cycling instead guarantees full coverage across
# every seeded key as long as -u >= len(CREDENTIALS) (see run.sh, which
# defaults -u to exactly that count via the /credential-count route
# below), and even spacing (not clumping) when it's fewer.
_credential_cycle = itertools.cycle(CREDENTIALS) if CREDENTIALS else None


@events.init.add_listener
def _on_init(environment, **kwargs):
    if not CREDENTIALS:
        sys.exit(
            f"{SEED_STATE_PATH} has no developer key issued against a supported auth type "
            f"({sorted(SUPPORTED_AUTH_TYPES)}) — seed a run with --auth-types authToken,basic "
            "(or add support for another auth type) before load-testing."
        )
    print(f"[load-test] loaded {len(CREDENTIALS)} usable credential(s) from {SEED_STATE_PATH}")

    # The web UI's own start form (its "Number of users"/"Spawn rate"
    # fields) reads its *defaults* straight from environment.parsed_options
    # (locust/web.py's index() — options.num_users/options.spawn_rate) —
    # confirmed live this was empty/1 by default, forcing an operator to
    # work out and type the right number themselves every time before
    # starting a run. Setting these here means the form already shows the
    # right value — one worker per available credential — the moment the
    # page loads, dynamically, however many keys this particular seed run
    # actually produced; nothing hardcoded, and nothing to type before
    # clicking "Start swarm" for the common case.
    environment.parsed_options.num_users = len(CREDENTIALS)
    environment.parsed_options.spawn_rate = len(CREDENTIALS)

    # /credential-count — lets a script driving this instance over HTTP
    # (run.sh) spin up exactly one simulated user per available key
    # without needing to know the count in advance or re-implement this
    # file's own credential-loading logic just to count them.
    if environment.web_ui:
        @environment.web_ui.app.route("/credential-count")
        def _credential_count():
            return {"count": len(CREDENTIALS)}


def _request_kwargs_for(credential: dict) -> dict:
    """Builds the requests-library kwargs that actually authenticate this
    credential's own auth_type — the one place a new auth type's request
    shape would be added."""
    if credential["auth_type"] == "authToken":
        # Classic's "standard auth" (use_standard_auth) reads the raw key
        # straight out of the configured auth_header_name (build_apidef,
        # ../lib/apidef.sh) with no "Bearer " prefix — this is not OAuth.
        return {"headers": {"Authorization": credential["raw_key"]}}
    if credential["auth_type"] == "basic":
        # For Basic Auth specifically, raw_key is the *username* and
        # password is the real password (see docs/SEEDING_GUIDE.md) —
        # requests' own `auth=(user, pass)` tuple handles the header.
        return {"auth": (credential["raw_key"], credential["password"])}
    raise AssertionError(f"unreachable: {credential['auth_type']!r} should have been filtered by SUPPORTED_AUTH_TYPES")


class SeededDeveloper(HttpUser):
    """One simulated developer, calling the one API their own seeded key
    was actually issued for — repeatedly, at wait_time's own pace,
    authenticated exactly like the real classic developer this credential
    came from would have to be."""

    # constant_pacing (not a random between()) — this worker's own key has
    # a real, finite quota, so the point is a *predictable* ceiling on how
    # often it's called, not variety in the wait. See PACING_SECONDS/
    # LOAD_TEST_RPS above for what actually sets this and why.
    wait_time = constant_pacing(PACING_SECONDS)
    host = _DEFAULT_HOST

    def on_start(self):
        self.credential = next(_credential_cycle)

    @task
    def call_my_api(self):
        credential = self.credential
        kwargs = _request_kwargs_for(credential)
        # httpbin's own /anything — accepts any method/body and echoes
        # back what it received, unlike e.g. /get (GET-only) — the
        # standard httpbin endpoint for exactly this kind of generic
        # load-test traffic. credential["url"] already ends in "/" (its
        # own listen_path always does, see seed.sh), so this is just the
        # one further path segment strip_listen_path forwards straight
        # through to PROXY_TARGET (../lib/apidef.sh).
        url = credential["url"] + "anything"
        # `name=` groups Locust's stats by auth_type+API rather than by
        # raw URL — every developer sharing one api_id already has the
        # identical URL, so this is purely a friendlier label, not a
        # dedup mechanism.
        self.client.get(url, name=f"{credential['auth_type']}:{credential['api_name']}", **kwargs)
