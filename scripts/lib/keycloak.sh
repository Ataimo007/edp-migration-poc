# keycloak.sh — helpers for talking to this stack's own Keycloak instance
# (the external IdP used for OpenID Connect / DCR scenarios). Every
# caller already has scripts/lib/common.sh sourced first (for curl/jq
# helpers and .env, which this file reads KEYCLOAK_HOST_PORT/
# KEYCLOAK_ADMIN_USER/KEYCLOAK_ADMIN_PASSWORD from).

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:${KEYCLOAK_HOST_PORT:-8180}}"

# kc_admin_token — authenticates as the Keycloak admin (master realm,
# admin-cli client, password grant) and prints a bearer token.
kc_admin_token() {
  curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=admin-cli&username=${KEYCLOAK_ADMIN_USER:-admin}&password=${KEYCLOAK_ADMIN_PASSWORD:-admin1234}" \
    | jq -r '.access_token // empty'
}

# ensure_keycloak_realm REALM — creates REALM if it doesn't already exist
# (idempotent, safe to call on every bootstrap.sh run). Prints nothing;
# use realm_issuer_url below to get the URL DCR setup actually needs.
ensure_keycloak_realm() {
  local realm="$1" token status
  token=$(kc_admin_token)
  [[ -n "$token" ]] || { err "could not authenticate to Keycloak's admin API"; return 1; }

  status=$(curl -s -o /dev/null -w '%{http_code}' "${KEYCLOAK_URL}/admin/realms/${realm}" -H "Authorization: Bearer ${token}")
  if [[ "$status" == "200" ]]; then
    info "Keycloak realm '${realm}' already exists — nothing to do"
    return 0
  fi

  status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${KEYCLOAK_URL}/admin/realms" \
    -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" \
    --data "$(jq -n --arg realm "$realm" '{realm: $realm, enabled: true}')")
  if [[ "$status" == "201" ]]; then
    ok "created Keycloak realm '${realm}'"
  else
    err "creating Keycloak realm '${realm}' failed (HTTP ${status})"
    return 1
  fi
}

# realm_issuer_url REALM — prints the realm's OIDC issuer URL (what a
# DCR/OpenID Connect setup's "issuer" field expects) — confirmed live to
# exactly match KC_HOSTNAME (docker-compose.yml), i.e. whatever
# KEYCLOAK_HOST_PORT currently is, not a fixed value.
realm_issuer_url() {
  local realm="$1"
  echo "${KEYCLOAK_URL}/realms/${realm}"
}
