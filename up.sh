#!/usr/bin/env bash
# up.sh — the one-command quickstart: brings up the full docker compose
# stack, waits for it to be healthy, bootstraps a Classic Portal
# organisation, and seeds it at the given scale (seed.sh also bootstraps
# itself if needed, so calling it directly without up.sh works too — this
# explicit call just keeps up.sh's own output/ordering obvious). See
# README.md for the manual, step-by-step version of exactly what this
# script automates.
#
# Usage: ./up.sh [options] [seed.sh options]
#        ./up.sh --help
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source scripts/lib/common.sh
require_cmd docker curl jq

# usage_own prints only *this script's* own options — the block also
# reused (deliberately not the full, seed.sh-embedding usage() below) when
# scripts/seed.sh itself already printed its own specific error and usage
# for a bad seed.sh-bound flag (see the pre-flight validation call below):
# that already covers seed.sh's own options in full, so repeating them
# here would just be noise — this only adds the half of the picture that
# seed.sh's own usage() can't know about, up.sh's own flags.
usage_own() {
  cat <<EOF
Usage: $(basename "$0") [options] [seed.sh options]

Brings up the full docker compose stack, waits for it to be healthy,
bootstraps a Classic Portal organisation, and seeds it — one command
instead of docker compose up -d + bootstrap.sh + seed.sh by hand. Any
option not listed below (--scale, --auth-types, --quota-min, ...) is
passed straight through to scripts/seed.sh — see scripts/seed.sh --help
for the full list, or run this script with --help to see both at once.

Options:
  --fresh      tear down and wipe all volumes first (scripts/reset.sh
               --full — prompts for confirmation), for a genuinely clean
               start in one command instead of two
  --dev-ports  switch .env's *_HOST_PORT values to the exact ones
               edp-migrate's own Setup wizard prefills by default
               (13000/13001/18080/15432/16379/18180) instead of this
               repo's plain-port defaults (3000/3001/8080/5432/6379/8180)
               — trades "won't collide with a real local Tyk stack" for
               "the wizard needs zero manual configuration to find this one".
               Every run sets .env's ports one way or the other (dev
               values with the flag, plain defaults without it) — never a
               one-way switch that leaves an earlier run's choice stuck
               until manually undone.
  --dev        core-tool development only: build edp-migrate from this
               repo's own local source (docker-compose.dev.yml) instead
               of pulling the published EDP_MIGRATE_IMAGE, so an
               in-progress change to the core tool shows up here without
               cutting a release first. Everyone else should never need
               this flag.
  --load-test  also bring up the "locust" service (docker-compose.yml),
               which autostarts real, continuous traffic against the
               Gateway the moment it comes up — one worker per seeded
               developer key. Off by default: this generates real load
               (and consumes real Policy quota) the instant it starts,
               not something a plain quickstart should do without
               asking. scripts/load-test/README.md has the full story.
  --load-test-rps N   requests per second *each worker* (one per key,
               never an aggregate figure) targets — implies --load-test.
               Default: 0.5. Sizing this against what your seeded
               Policies can actually sustain is scripts/seed.sh's own
               --quota-min/--quota-max's job, not this flag's — see
               that script's own comment for why (this used to be a
               real problem: 0.5 rps/worker exhausted a low-tier
               Policy's default 1000-request daily quota in about half
               an hour, before quota itself became configurable).
  --seed-state-volume   store the "seed"/"locust" services' shared
               .seed-state/ (run-*.yaml|json — every generated API,
               Policy, developer and key) in a named Docker volume
               instead of this repo's default plain host bind mount
               (poc-environment/.seed-state/). Only needed where a host
               bind mount doesn't work — some devcontainer/remote setups
               run Docker via a forwarded socket to a *different*
               machine's daemon, which can't share this checkout's own
               path at all. With this flag, use scripts/seed-state.sh
               to read the state instead of opening the directory
               directly. See docker-compose.namedvolume.yml's own
               comment for the full story.
  -h, --help   this help
EOF
}

# usage prints this script's own options (usage_own, above) plus the
# complete scripts/seed.sh option list appended below it — every flag this
# tool understands, in one place, since seed.sh options are just as valid
# to pass to up.sh directly (they're forwarded verbatim, see SEED_ARGS
# below) as up.sh's own. `scripts/seed.sh --help` is pure, side-effect-free
# output (no bootstrap/DASH_TOKEN dependency — see that script's own
# argument-parsing order) so calling it here is always safe, regardless of
# whether this stack has ever been brought up.
usage() {
  usage_own
  echo
  echo "scripts/seed.sh's own options (forwarded verbatim — any of these work here too):"
  echo
  scripts/seed.sh --help
}

DEV_PORTS=0
DEV_BUILD=0
LOAD_TEST=0
LOAD_TEST_RPS=""
SEED_STATE_VOLUME=0
# SEED_ARGS collects everything that isn't one of *this script's own*
# flags above, in original order, to forward to the "seed" service
# untouched. Deliberately not a `while [[ "${1:-}" == --* ]]` loop that
# stops at the first flag it doesn't recognize (as this used to be) —
# confirmed live that broke `./up.sh --dev --auth-types authToken
# --apis-per-type 20 --load-test`: --auth-types isn't one of up.sh's own
# flags, so the old loop stopped right there and forwarded everything
# after it — --load-test included — straight to seed.sh, which
# (correctly) rejected --load-test as an option *it* doesn't know about.
# Scanning every argument instead means up.sh's own flags are recognized
# no matter where they fall relative to seed.sh's own pass-through flags.
SEED_ARGS=()
FRESH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --fresh) FRESH=1; shift ;;
    --dev-ports) DEV_PORTS=1; shift ;;
    --dev) DEV_BUILD=1; shift ;;
    --load-test) LOAD_TEST=1; shift ;;
    --load-test-rps) LOAD_TEST_RPS="$2"; LOAD_TEST=1; shift 2 ;;
    --seed-state-volume) SEED_STATE_VOLUME=1; shift ;;
    *) SEED_ARGS+=("$1"); shift ;;
  esac
done
export LOAD_TEST_RPS

# Pre-flight: validate every seed.sh-bound flag/value *before* doing
# anything else at all — no --fresh teardown, no docker compose pull/up,
# no bootstrap.sh. scripts/seed.sh --validate-only (see that script's own
# comment on it) parses and checks exactly what a real seed.sh run would
# (unknown flags, an out-of-range --rate-min/--quota-max, an unknown
# --scale/--state-format, ...), then exits immediately — zero dependency
# on this stack ever having been bootstrapped. Confirmed live this used to
# be a real, wasteful problem: a typo'd flag (e.g. --rubish) only surfaced
# once seed.sh itself finally ran, by which point the whole stack (and a
# --fresh teardown, if one was also given) had already happened for
# nothing. scripts/seed.sh's own error + full usage already prints on
# failure here — usage_own (not the full, seed.sh-embedding usage) adds
# just the up.sh-side half of the picture, so a typo'd *up.sh* flag
# (rather than a seed.sh one) is never left undocumented in this same
# error output.
if ! scripts/seed.sh --validate-only "${SEED_ARGS[@]}"; then
  echo >&2
  usage_own >&2
  exit 1
fi

# --fresh itself is deliberately deferred to here, after the validation
# above — running the (destructive, confirmation-prompting) teardown
# before checking the rest of this same command's flags would mean a
# typo anywhere else in the command still tore down the stack for nothing.
if [[ $FRESH -eq 1 ]]; then
  scripts/reset.sh --full
fi

COMPOSE=(docker compose -f docker-compose.yml)
if [[ $DEV_BUILD -eq 1 ]]; then
  COMPOSE+=(-f docker-compose.dev.yml)
fi
if [[ $SEED_STATE_VOLUME -eq 1 ]]; then
  COMPOSE+=(-f docker-compose.namedvolume.yml)
fi
if [[ $LOAD_TEST -eq 1 ]]; then
  COMPOSE+=(--profile load-test)
fi

if [[ ! -f .env ]]; then
  info "no .env found — creating one from .env.example"
  cp .env.example .env
  read -r -s -p "Paste your Tyk trial license key (see README.md Prerequisites): " license
  echo
  [[ -n "$license" ]] || die "a license is required — get one at https://tyk.io/sign-up/ (choose \"guided evaluation\")"
  # macOS/BSD sed needs -i '' ; GNU sed needs -i — this covers both.
  sed -i.bak "s#^DASH_LICENSE=.*#DASH_LICENSE=${license}#" .env && rm -f .env.bak
  ok "wrote .env"
fi

# EDP's own bootstrap admin — generated fresh rather than left as
# whatever placeholder .env.example ships, so nobody's real personal
# email/password ends up baked into a config file this repo's own sync
# workflow mirrors to a public repo (confirmed live: an earlier, unrelated
# checked-in default did exactly that before this existed).
if ! grep -q "^EDP_ADMIN_EMAIL=." .env 2>/dev/null; then
  edp_admin_email="edp-admin-$((RANDOM % 100000))@example-poc.dev"
  edp_admin_password="$(gen_password)"
  if grep -q "^EDP_ADMIN_EMAIL=" .env; then
    sed -i.bak "s#^EDP_ADMIN_EMAIL=.*#EDP_ADMIN_EMAIL=${edp_admin_email}#" .env
  else
    echo "EDP_ADMIN_EMAIL=${edp_admin_email}" >> .env
  fi
  if grep -q "^EDP_ADMIN_PASSWORD=" .env; then
    sed -i.bak "s#^EDP_ADMIN_PASSWORD=.*#EDP_ADMIN_PASSWORD=${edp_admin_password}#" .env
  else
    echo "EDP_ADMIN_PASSWORD=${edp_admin_password}" >> .env
  fi
  rm -f .env.bak
  ok "generated EDP admin credentials"
fi

if [[ $DEV_PORTS -eq 1 ]]; then
  info "--dev-ports: switching .env to edp-migrate's own wizard-default ports..."
  sed -i.bak \
    -e "s/^DASHBOARD_HOST_PORT=.*/DASHBOARD_HOST_PORT=13000/" \
    -e "s/^PORTAL_HOST_PORT=.*/PORTAL_HOST_PORT=13001/" \
    -e "s/^GATEWAY_HOST_PORT=.*/GATEWAY_HOST_PORT=18080/" \
    -e "s/^POSTGRES_HOST_PORT=.*/POSTGRES_HOST_PORT=15432/" \
    -e "s/^REDIS_HOST_PORT=.*/REDIS_HOST_PORT=16379/" \
    -e "s/^KEYCLOAK_HOST_PORT=.*/KEYCLOAK_HOST_PORT=18180/" \
    .env && rm -f .env.bak
  ok "wrote dev ports to .env"
else
  # Symmetric reset, not just a one-way switch: without this, .env keeps
  # whatever a *previous* --dev-ports run last wrote (e.g. GATEWAY_HOST_PORT
  # staying 18080 forever), so a later plain `./up.sh` — no --dev-ports —
  # would silently keep printing the dev-ports URLs below instead of the
  # plain-port ones its own lack of a flag implies. Confirmed live: this is
  # exactly what "Gateway: http://localhost:18080" without --dev-ports
  # turned out to be.
  sed -i.bak \
    -e "s/^DASHBOARD_HOST_PORT=.*/DASHBOARD_HOST_PORT=3000/" \
    -e "s/^PORTAL_HOST_PORT=.*/PORTAL_HOST_PORT=3001/" \
    -e "s/^GATEWAY_HOST_PORT=.*/GATEWAY_HOST_PORT=8080/" \
    -e "s/^POSTGRES_HOST_PORT=.*/POSTGRES_HOST_PORT=5432/" \
    -e "s/^REDIS_HOST_PORT=.*/REDIS_HOST_PORT=6379/" \
    -e "s/^KEYCLOAK_HOST_PORT=.*/KEYCLOAK_HOST_PORT=8180/" \
    .env && rm -f .env.bak
fi

# Re-source now that .env definitely exists (and may have just changed) —
# common.sh's own sourcing above ran before .env existed on a fresh
# checkout, so this is what makes the final URL printout below accurate.
set -a
# shellcheck source=/dev/null
source .env
set +a

# keycloak.sh's own KEYCLOAK_URL is computed once, at source time, from
# whatever KEYCLOAK_HOST_PORT already is — sourcing it any earlier than
# this (it used to happen right after common.sh, before the --dev-ports/
# reset logic above ever touched .env) left it permanently stuck on
# .env's *previous* value: confirmed live, a plain `./up.sh` right after
# an earlier `--dev-ports` run correctly reset .env's own
# KEYCLOAK_HOST_PORT back to 8180, but the final summary's "Keycloak
# realm for DCR" line (realm_issuer_url, below) still printed 18180,
# since KEYCLOAK_URL itself never got recomputed against the reset value.
# shellcheck source=scripts/lib/keycloak.sh
source scripts/lib/keycloak.sh

if [[ $DEV_BUILD -eq 1 ]]; then
  info "--dev: pulling every image except edp-migrate (built locally instead)..."
  "${COMPOSE[@]}" pull --ignore-buildable || die "docker compose pull failed — see the output above"
  info "building edp-migrate from local source and bringing the stack up..."
  "${COMPOSE[@]}" up -d --build || die "docker compose up failed — see the output above"
else
  info "pulling the latest images (docker won't do this on its own for a tag it already has cached)..."
  "${COMPOSE[@]}" pull --ignore-buildable || die "docker compose pull failed — see the output above"

  # --build: "seed" and "locust" are always locally built (docker-compose.yml
  # has no image: for either, only build:), never pulled — without this,
  # `up -d`/`run` silently reuse whatever image was last built, even after
  # editing scripts/seed/ or scripts/load-test/ source. Confirmed live this
  # is a real, not hypothetical, gap: a fix to scripts/lib/classic_portal.sh
  # (the catalogue-details blank-page bug) sat unbuilt for a full day of
  # reseeding before anyone noticed the container never picked it up.
  info "bringing the stack up..."
  "${COMPOSE[@]}" up -d --build || die "docker compose up failed — see the output above"
fi

scripts/bootstrap.sh || die "bootstrap.sh failed — see the output above"
# Runs as its own compose service (docker-compose.yml's "seed", profile
# "seed" — never started by the plain `up -d` above), not this script's
# own host shell, so its output lands wherever docker-compose.yml's
# .seed-state/ mount points — this repo's own host bind mount
# (poc-environment/.seed-state/) by default, or the "seed-state" named
# volume the "locust" service also mounts when --seed-state-volume was
# passed. `--profile seed` is what makes `run` honor a service that's
# otherwise excluded from every profile-less compose command (`up -d`
# included) — without it, compose refuses to run a profile-gated service
# at all.
#
# Checked, not left to fail silently into the "POC environment is up"
# banner below — confirmed live this used to be a real gap: seed.sh
# failing here (a bad flag that somehow slipped past the pre-flight
# --validate-only check above, or a genuine runtime failure) still let
# this script fall through to printing a full success summary afterward.
"${COMPOSE[@]}" --profile seed run --rm --build seed "${SEED_ARGS[@]}" || die "seeding failed — see the output above"

# bootstrap.sh just wrote/confirmed this — source it so the summary below
# can print the real Dashboard admin login directly instead of just
# pointing at the file.
# shellcheck source=/dev/null
source .runtime.env

cat <<EOF

=========================================================
POC environment is up.

  Classic Dashboard:   http://localhost:${DASHBOARD_HOST_PORT:-3000}
  Enterprise Portal:   http://localhost:${PORTAL_HOST_PORT:-3001}
  Gateway:             http://localhost:${GATEWAY_HOST_PORT:-8080}
  Keycloak:            http://localhost:${KEYCLOAK_HOST_PORT:-8180}
  edp-migrate:         http://localhost:${EDP_MIGRATE_HOST_PORT:-9090}
$(if [[ $LOAD_TEST -eq 1 ]]; then
  echo "  Locust (load test):  http://localhost:${LOCUST_HOST_PORT:-8089}  (autostarting at ${LOAD_TEST_RPS:-0.5} rps/worker — see scripts/load-test/README.md)"
else
  echo "  Locust (load test):  not started — re-run with --load-test (or --load-test-rps N) to bring it up"
fi)
$(if [[ $SEED_STATE_VOLUME -eq 1 ]]; then
  echo "  Seed state:          named volume — read it with ./scripts/seed-state.sh list|show"
else
  echo "  Seed state:          poc-environment/.seed-state/  (run-*.yaml — every generated API, Policy, developer, key)"
fi)

Credentials:
  Classic Dashboard admin:  ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}
  Enterprise Portal admin:  ${EDP_ADMIN_EMAIL} / ${EDP_ADMIN_PASSWORD}
  Postgres (all 3 DBs):     user=postgres password=topsecretpassword host=localhost port=${POSTGRES_HOST_PORT:-5432}
                            (databases: tyk_analytics, tyk_portal, keycloak)
  Keycloak admin console:  ${KEYCLOAK_ADMIN_USER:-admin} / ${KEYCLOAK_ADMIN_PASSWORD:-admin1234}
  Keycloak realm for DCR:  tyk  (issuer: $(realm_issuer_url tyk))

Open edp-migrate's Setup wizard next — see docs/MIGRATION_WALKTHROUGH.md.
=========================================================
EOF
