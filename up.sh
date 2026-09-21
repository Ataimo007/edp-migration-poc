#!/usr/bin/env bash
# up.sh — the one-command quickstart: brings up the full docker compose
# stack, waits for it to be healthy, bootstraps a Classic Portal
# organisation, and seeds it at the given scale. See README.md for the
# manual, step-by-step version of exactly what this script automates.
#
# Usage: ./up.sh [--scale small|medium|large]   (default: small)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

source scripts/lib/common.sh
require_cmd docker curl jq

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

info "bringing the stack up (this can take a minute the first time, while images pull/build)..."
docker compose up -d || die "docker compose up failed — see the output above"

scripts/bootstrap.sh
scripts/seed.sh "$@"

cat <<EOF

=========================================================
POC environment is up.

  Classic Dashboard:   http://localhost:${DASHBOARD_HOST_PORT:-13000}
  Enterprise Portal:   http://localhost:${PORTAL_HOST_PORT:-13001}
  Gateway:             http://localhost:${GATEWAY_HOST_PORT:-18080}
  Keycloak:            http://localhost:${KEYCLOAK_HOST_PORT:-18180}
  edp-migrate:         http://localhost:${EDP_MIGRATE_HOST_PORT:-9090}

See .runtime.env for the Dashboard admin login this run created.
Open edp-migrate's Setup wizard next — see docs/MIGRATION_WALKTHROUGH.md.
=========================================================
EOF
