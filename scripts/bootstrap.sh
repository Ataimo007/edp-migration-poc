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
# shellcheck source=lib/keycloak.sh
source scripts/lib/keycloak.sh

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $(basename "$0")

One-time (idempotent) setup of a fresh Classic Dashboard organisation +
admin API user on top of an already-running docker compose stack
(docker-compose.yml at the repo root). Run this once after
'docker compose up -d', before scripts/seed.sh — or just use ./up.sh,
which runs both for you in order.

Writes .runtime.env (gitignored) with DASHBOARD_URL/ADMIN_SECRET/ORG_ID/
DASH_TOKEN — every other script in this directory sources it. Safe to
re-run: if .runtime.env already has working credentials, this exits
immediately without creating anything new (beyond the one-time
tyk-dashboard restart below, if still needed). Takes no options.

May restart the "tyk-dashboard" container once (docker compose restart
tyk-dashboard, a few seconds of downtime) if the Classic Portal isn't
being served yet — a confirmed tyk-analytics bug means its own portal
routes only ever take effect at that container's own process startup,
never on a live CNAME/config change, so this org's portal genuinely
cannot come up without one restart after it's first created. See
scripts/lib/classic_portal.sh's ensure_portal_routes_live for the full
story. Skipped automatically once the portal is confirmed live.
EOF
  exit 0
fi

require_cmd curl jq docker

DASHBOARD_URL="${DASHBOARD_URL:-http://localhost:${DASHBOARD_HOST_PORT:-3000}}"
ADMIN_SECRET="${ADMIN_SECRET:-12345}" # TYK_DB_ADMINSECRET, confs/tyk_analytics.env — not a secret worth rotating for a local POC stack
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example-poc.dev}"
ADMIN_FIRST="${ADMIN_FIRST:-POC}"
ADMIN_LAST="${ADMIN_LAST:-Admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-PocAdmin123!}"
ORG_NAME="${ORG_NAME:-$SEED_PREFIX EDP Migration POC}"
RUNTIME_FILE="$(pwd)/.runtime.env"
KEYCLOAK_REALM="tyk"

wait_for_http "${DASHBOARD_URL}/hello" 90 2 || die "Dashboard never became reachable — check 'docker compose logs tyk-dashboard'"

# Idempotent, and deliberately ahead of the "already bootstrapped, nothing
# to do" short-circuit below — this needs to run every time regardless of
# whether the Classic Dashboard side already exists, since a --fresh
# restart wipes Keycloak's own database independently of tyk_analytics.
wait_for_http "${KEYCLOAK_URL}/realms/master/.well-known/openid-configuration" 90 2 \
  || die "Keycloak never became reachable — check 'docker compose logs keycloak'"
ensure_keycloak_realm "$KEYCLOAK_REALM" || die "creating Keycloak realm '$KEYCLOAK_REALM' failed"

if [[ -f "$RUNTIME_FILE" ]]; then
  info "found existing $RUNTIME_FILE — verifying it still works against $DASHBOARD_URL"
  # shellcheck source=/dev/null
  source "$RUNTIME_FILE"
  check=$(dash GET /api/apis)
  if [[ "$(json_get "$check" '.apis // empty')" != "" || "$(json_get "$check" '.apis')" == "[]" ]]; then
    ok "existing credentials in $RUNTIME_FILE are still valid — nothing to bootstrap"
    # ensure_cname is cheap and idempotent (a plain overwrite server-side)
    # — run it even on this shortcut path, so an environment bootstrapped
    # before this existed still picks it up on its next plain `up.sh`,
    # without needing a full --fresh/down.sh teardown just for this.
    # shellcheck source=lib/classic_portal.sh
    source scripts/lib/classic_portal.sh
    ensure_cname "${DASHBOARD_URL#http://}"
    ensure_portal_routes_live
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

# Without this, this admin can reset its own password (any user can, once
# it's unset — see the reset call right below) but gets a 403 trying to
# reset anyone *else's* later (confirmed live: seed.sh's --admin-users
# creates more admins using this same account's DASH_TOKEN). Granting
# "ResetPassword" needs the admin-secret-authenticated endpoint
# specifically — the plain PUT /api/users/{id} used elsewhere in this
# file rejects it outright ("only accessible via the Admin API").
allow_reset_resp=$(curl -s -w '\n%{http_code}' -X PUT "${DASHBOARD_URL}/admin/users/${USER_ID}/actions/allow_reset_passwords" \
  -H "admin-auth: ${ADMIN_SECRET}")
allow_reset_status="${allow_reset_resp##*$'\n'}"
[[ "$allow_reset_status" == "200" ]] || die "granting ResetPassword to the admin user failed (HTTP $allow_reset_status): ${allow_reset_resp%$'\n'*}"
ok "admin user can now reset other users' passwords too"

# The permission grant above changed the User row in the DB, but this
# admin's *already-issued* DASH_TOKEN is tied to a session created at the
# original CreateUser call and won't reflect it (confirmed live: the old
# token kept 403ing on cross-user resets even after the DB row genuinely
# showed the new right). Rotating its own key forces a brand new session
# built from a fresh DB read, which does pick it up — but the rotate
# endpoint itself never returns the new key (just "session renewed"), so
# it has to be looked up separately afterward via the admin-secret path.
rotate_resp=$(curl -s -w '\n%{http_code}' -X PUT "${DASHBOARD_URL}/api/users/${USER_ID}/actions/key/reset" \
  -H "authorization: ${DASH_TOKEN}")
rotate_status="${rotate_resp##*$'\n'}"
[[ "$rotate_status" == "200" ]] || die "rotating the admin's token failed (HTTP $rotate_status): ${rotate_resp%$'\n'*}"
DASH_TOKEN=$(curl -s "${DASHBOARD_URL}/admin/users/${USER_ID}" -H "admin-auth: ${ADMIN_SECRET}" \
  | jq -r '.access_key // .Meta.access_key // empty')
[[ -n "$DASH_TOKEN" ]] || die "rotated the admin's token but couldn't look up the new value"
ok "admin token rotated so it reflects the new permission"

# POST, not PUT — the Dashboard registers this route as Post() only; a PUT
# silently 404s. Found live: bootstrap.sh reported "admin password set"
# every time (its curl call discarded the response with -o /dev/null) while
# the password was never actually changed, so every fresh stack's admin
# login failed. Checking the response now so that can't happen silently
# again.
reset_resp=$(curl -s -w '\n%{http_code}' -X POST "${DASHBOARD_URL}/api/users/${USER_ID}/actions/reset" \
  -H "Content-Type: application/json" -H "authorization: ${DASH_TOKEN}" \
  --data "$(jq -n --arg pw "$ADMIN_PASSWORD" '{ new_password: $pw, user_permissions: { IsAdmin: "admin" } }')")
reset_status="${reset_resp##*$'\n'}"
[[ "$reset_status" == "200" ]] || die "setting admin password failed (HTTP $reset_status): ${reset_resp%$'\n'*}"
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
# Strips DASHBOARD_URL's own scheme (http(s)://) — the CNAME field itself
# is just host[:port], no scheme, confirmed via source (see ensure_cname's
# own comment, lib/classic_portal.sh). Using DASHBOARD_URL's own host is
# deliberate, not a hardcoded "localhost:3000": whatever address this
# script itself just proved reachable enough to bootstrap through is also
# the address the operator's own browser needs "Open Portal" to point at.
ensure_cname "${DASHBOARD_URL#http://}"
ensure_menus
ensure_css
ensure_js
ensure_homepage
ensure_portal_routes_live

cat >&2 <<EOF

---------------------------------------------------------
Classic Dashboard bootstrapped.

  Dashboard UI:   ${DASHBOARD_URL}
  Login:          ${ADMIN_EMAIL} / ${ADMIN_PASSWORD}
  Org ID:         ${ORG_ID}

  Keycloak realm: ${KEYCLOAK_REALM}  (issuer: $(realm_issuer_url "$KEYCLOAK_REALM"))

Next: scripts/seed.sh --scale small
---------------------------------------------------------
EOF
