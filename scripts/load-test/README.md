# Load-testing the seeded APIs

A [Locust](https://locust.io/) load runner that calls the APIs the `seed`
service creates, authenticated with the real developer keys it issued —
no separate setup or hand-copied credentials, just the
`.seed-state/run-*.yaml` file it already writes.

Not part of the always-up stack — bring it up with `./up.sh --load-test`
(or `--load-test-rps N`), since it generates real, continuous traffic
against the Gateway the moment it starts. `./up.sh` also runs seeding
itself, via its own one-shot `seed` compose service (`docker compose run
--rm seed ...` — never started by a plain `docker compose up -d`, see
that service's own `profiles:`) rather than a plain host script,
specifically so its output lands wherever `locust` can also see it —
see `scripts/seed/Dockerfile`'s own comment for why.

## How it finds credentials

`scripts/seed.sh` records, per issued key: which seeded API it's valid
against (`api_id`), and per seeded API: its `auth_type`, `listen_path`,
and both a host-facing `url` and an internal-docker-network `internal_url`
(`http://tyk-gateway:8080/...` — what the `locust` container actually
uses, since it runs on this same "tyk" network). This load runner joins
the two — one simulated user per usable developer key, assigned in a
fixed round-robin order (not randomly — see `locustfile.py`'s own
comment on why: with a small `-u` relative to a much larger credential
pool, random assignment could leave most seeded APIs never called at
all, purely by chance). `run.sh` defaults `-u` to exactly the number of
usable credentials (`GET /credential-count`), so every seeded key gets
its own worker by default — every worker repeatedly calls its own key's
one API at httpbin's `/anything` endpoint, authenticated exactly the way
that API's `auth_type` actually requires.

Want to inspect the actual credentials/keys yourself (not just let this
load runner use them)? By default `.seed-state/run-*.yaml` shows up
directly on your host at `poc-environment/.seed-state/` — just open it.

Ran the stack with `./up.sh --seed-state-volume` instead (some
devcontainer/remote Docker setups can't bind-mount this repo's own path
onto the host at all — see `../../docker-compose.namedvolume.yml`'s own
comment for why)? `.seed-state/` lives in a named volume in that case,
not on your host disk — use `../seed-state.sh` instead:

```sh
./scripts/seed-state.sh list
./scripts/seed-state.sh show           # most recent run
./scripts/seed-state.sh show run-1234567890123.yaml
```

Only `authToken` (the raw key, unprefixed, in the `Authorization` header)
and `basic` (HTTP Basic Auth — the classic gotcha: `raw_key` is the
*username*, `password` holds the real password) are wired up right now.
A key issued against any other auth type (`hmac`, `jwt`, `oauth`,
`openid`, `mutualTLS`) is skipped, with a one-time warning naming it —
each needs real request-time work (a signed request, a minted/refreshed
token, a client TLS handshake) that a flat credential pair can't drive
generically. Seed with `--auth-types authToken,basic` if you want every
seeded key to actually be load-testable.

## Usage

`./up.sh` already started it, and traffic is already flowing by the time
it's up — no form to fill in, nothing to click. `entrypoint.sh` passes
Locust its own `--autostart`, and `locustfile.py`'s own init hook sets
`num_users`/`spawn_rate` to the number of usable credentials *before*
that autostart happens — so the swarm launches immediately, sized to
exactly one worker per available developer key, dynamically, however
many that seed run actually produced. Open the web UI any time just to
watch it:

```
http://localhost:${LOCUST_HOST_PORT:-8089}
```

It keeps running indefinitely (no `--autoquit`) until you stop/restart it
yourself from the UI, or via `run.sh` below.

`entrypoint.sh` makes the container wait for the `seed` service to have
actually written a `.seed-state/run-*.yaml|json` file before starting
Locust for real (this container starts with the rest of the stack, before
`up.sh` gets around to running `seed`) — give it a few seconds after
seeding finishes if the page isn't answering yet.

Both `seed` and `locust` mount the same `.seed-state/` (a host bind mount
by default, or the `seed-state` named volume under `--seed-state-volume`
— `docker-compose.yml`) — a real, live, shared filesystem, not a copy:
whatever `seed` writes is visible here immediately, no restart needed
just to make the *file* show up.

**Re-seeded, or ran `scripts/reset.sh`, after the stack was already up?**
The new file is already there (see above) — Locust just hasn't re-read it
yet, since it only loads credentials once, at its own startup:

```sh
docker compose restart locust
```

Targeting one *specific* seed run instead of "whichever file is newest"
just needs `SEED_STATE_FILE` set before Locust starts (the volume already
has every run.sh ever wrote, so no copying anything in):

```sh
SEED_STATE_FILE=.seed-state/run-1234567890123.yaml docker compose up -d --force-recreate locust
```

**Want a bounded run with a final summary instead of the indefinite one
that's already going?** `./scripts/load-test/run.sh` re-targets that same
running instance over Locust's own REST API (`POST /swarm`,
`GET /stats/requests`, `GET /stop`) for a fixed duration, then stops it
and prints final stats — no second `locust` process, no browser:

```sh
cd poc-environment
./scripts/load-test/run.sh                # one worker per available key, 2 minutes
./scripts/load-test/run.sh -u 100 -r 10 -t 5m
```

(An earlier version of this tried running a second `locust` process
inside the container via `docker compose exec` instead — confirmed live,
repeatedly, that it returns control to the shell almost immediately
regardless of the requested duration, even though `docker top` shows the
spawned process still genuinely running server-side — an exec/signal
quirk in this environment's own nested Docker setup. Driving the already-
running instance over its own REST API sidesteps that entirely, and is
the more idiomatic way to script a persistent Locust instance anyway.)

## What it actually measures

Every request goes straight through `tyk-gateway` to the real proxied
target (`httpbin` — see `../lib/apidef.sh`'s `PROXY_TARGET`), so this
exercises the Gateway's own key-auth/rate-limit/quota path for real, not
just the Dashboard/Portal's metadata. Locust's own stats break results
down per `auth_type:api_name` (every developer sharing one seeded API has
an identical URL, so grouping by URL alone would already work — the
label's just friendlier).

Nothing here touches Classic Portal's own data — `scripts/reset.sh` still
works exactly as documented afterward.
