#!/usr/bin/env bash
# up.sh — the one-command quickstart: brings up the full docker compose
# stack, waits for it to be healthy, bootstraps a Classic Portal
# organisation, and seeds it at the given scale (seed.sh also bootstraps
# itself if needed, so calling it directly without up.sh works too — this
# explicit call just keeps up.sh's own output/ordering obvious). See
# README.md for the manual, step-by-step version of exactly what this
# script automates.
#
# Usage: ./up.sh [--fresh] [--dev-ports] [--dev] [--scale small|medium|large] [seed.sh options]
#   --fresh      tear down and wipe all volumes first (scripts/reset.sh
#                --full — prompts for confirmation), for a genuinely clean
#                start in one command instead of two
#   --dev-ports  switch .env's *_HOST_PORT values to the exact ones
#                edp-migrate's own Setup wizard prefills by default
#                (13000/13001/18080/15432/16379/18180) instead of this
#                repo's plain-port defaults (3000/3001/8080/5432/6379/8180)
#                — trades "won't collide with a real local Tyk stack" for
#                "the wizard needs zero manual configuration to find this one".
#                Every run sets .env's ports one way or the other (dev
#                values with the flag, plain defaults without it) — never a
#                one-way switch that leaves an earlier run's choice stuck
#                until manually undone.
#   --dev        core-tool development only: build edp-migrate from this
#                repo's own local source (docker-compose.dev.yml) instead
#                of pulling the published EDP_MIGRATE_IMAGE, so an
#                in-progress change to the core tool shows up here without
#                cutting a release first. Everyone else should never need
#                this flag.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source scripts/lib/common.sh
# shellcheck source=scripts/lib/keycloak.sh
source scripts/lib/keycloak.sh
require_cmd docker curl jq

DEV_PORTS=0
DEV_BUILD=0
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --fresh) shift; scripts/reset.sh --full ;;
    --dev-ports) shift; DEV_PORTS=1 ;;
    --dev) shift; DEV_BUILD=1 ;;
    *) break ;;
  esac
done

COMPOSE=(docker compose)
if [[ $DEV_BUILD -eq 1 ]]; then
  COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.dev.yml)
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

if [[ $DEV_BUILD -eq 1 ]]; then
  info "--dev: pulling every image except edp-migrate (built locally instead)..."
  "${COMPOSE[@]}" pull --ignore-buildable || die "docker compose pull failed — see the output above"
  info "building edp-migrate from local source and bringing the stack up..."
  "${COMPOSE[@]}" up -d --build || die "docker compose up failed — see the output above"
else
  info "pulling the latest images (docker won't do this on its own for a tag it already has cached)..."
  "${COMPOSE[@]}" pull || die "docker compose pull failed — see the output above"

  info "bringing the stack up..."
  "${COMPOSE[@]}" up -d || die "docker compose up failed — see the output above"
fi

scripts/bootstrap.sh
scripts/seed.sh "$@"

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
