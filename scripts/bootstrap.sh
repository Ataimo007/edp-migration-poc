#!/usr/bin/env bash
# bootstrap.sh — one-time (idempotent) setup of a fresh Classic Dashboard
# organisation + admin API user on top of an already-running docker compose
# stack (docker-compose.yml at the repo root). Run this once after `docker
# compose up -d`, before seed.sh.
#
# Writes .runtime.env (gitignored) with DASHBOARD_URL/ADMIN_SECRET/ORG_ID/
# DASH_TOKEN — every other script in this directory sources it.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck source=lib/common.sh
source scripts/lib/common.sh

require_cmd curl jq docker

DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:${DASHBOARD_HOST_PORT:-13000}}"
ADMIN_SECRET="${ADMIN_SECRET:-12345}" # TYK_DB_ADMINSECRET, confs/tyk_analytics.env — not a secret worth rotating for a local POC stack
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example-poc.dev}"
ADMIN_FIRST="${ADMIN_FIRST:-POC}"
ADMIN_LAST="${ADMIN_LAST:-Admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-PocAdmin123!}"
ORG_NAME="${ORG_NAME:-$SEED_PREFIX EDP Migration POC}"
RUNTIME_FILE="$(pwd)/.runtime.env"

wait_for_http "${DASHBOARD_URL}/hello" 90 2 || die "Dashboard never became reachable — check 'docker compose logs tyk-dashboard'"

if [[ -f "$RUNTIME_FILE" ]]; then
  info "found existing $RUNTIME_FILE — verifying it still works against $DASHBOARD_URL"
  # shellcheck source=/dev/null
  source "$RUNTIME_FILE"
  check=$(dash GET /api/apis)
  if [[ "$(json_get "$check" '.apis // empty')" != "" || "$(json_get "$check" '.apis')" == "[]" ]]; then
    ok "existing credentials in $RUNTIME_FILE are still valid — nothing to bootstrap"
    exit 0
  fi
  warn "existing $RUNTIME_FILE credentials no longer work (stack was likely reset) — bootstrapping fresh"
fi

info "creating organisation '$ORG_NAME' ..."
create_org_resp=$(dash_admin POST /admin/organisations/ "$(jq -n --arg name "$ORG_NAME" '{
  owner_name: $name, cname_enabled: true, hybrid_enabled: true,
  event_options: { hashed_key_event: { redis: true }, key_event: { redis: true } }
}')")
ORG_ID=$(json_get "$create_org_resp" '.Meta // empty')
[[ -n "$ORG_ID" && "$ORG_ID" != "null" ]] || die "failed to create organisation: $create_org_resp"
ok "organisation created: $ORG_ID"

info "creating admin API user '$ADMIN_EMAIL' ..."
create_user_resp=$(dash_admin POST /admin/users/ "$(jq -n \
  --arg org "$ORG_ID" --arg first "$ADMIN_FIRST" --arg last "$ADMIN_LAST" --arg email "$ADMIN_EMAIL" \
  '{ org_id: $org, first_name: $first, last_name: $last, email_address: $email, active: true, user_permissions: { IsAdmin: "admin" } }')")
DASH_TOKEN=$(json_get "$create_user_resp" '.Meta.access_key // empty')
USER_ID=$(json_get "$create_user_resp" '.Meta.id // empty')
[[ -n "$DASH_TOKEN" && "$DASH_TOKEN" != "null" ]] || die "failed to create admin user: $create_user_resp"
ok "admin user created: $USER_ID"

curl -s -o /dev/null -X PUT "${DASHBOARD_URL}/api/users/${USER_ID}/actions/reset" \
  -H "Content-Type: application/json" -H "authorization: ${DASH_TOKEN}" \
  --data "$(jq -n --arg pw "$ADMIN_PASSWORD" '{ new_password: $pw, user_permissions: { IsAdmin: "admin" } }')"
ok "admin password set"

{
  echo "DASHBOARD_URL=$DASHBOARD_URL"
  echo "ADMIN_SECRET=$ADMIN_SECRET"
  echo "ORG_ID=$ORG_ID"
  echo "DASH_TOKEN=$DASH_TOKEN"
  echo "ADMIN_EMAIL=$ADMIN_EMAIL"
  echo "ADMIN_PASSWORD=$ADMIN_PASSWORD"
} > "$RUNTIME_FILE"
ok "wrote $RUNTIME_FILE"

# shellcheck source=lib/apidef.sh
source scripts/lib/apidef.sh
# shellcheck source=lib/classic_portal.sh
source scripts/lib/classic_portal.sh

ensure_portal_config
ensure_menus
ensure_css
ensure_js
ensure_homepage

cat >&2 <<EOF

---------------------------------------------------------
Classic Dashboard bootstrapped.

  Dashboard UI:   ${DASHBOARD_URL}
  Login:          ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}
  Org ID:         ${ORG_ID}

Next: scripts/seed.sh --scale small
---------------------------------------------------------
EOF
