#!/usr/bin/env bash
# Builds a Tyk Gateway API Definition JSON body per classic auth type,
# matching the exact flags the classic Dashboard's own getAuthType() reads
# (dashboard/model_api_definition.go, mirrored in edp-migration's
# internal/migration/authtype.go) — so every seeded API lands in the
# catalogue auth-type bucket its name says it will.
#
# Supported AUTH_TYPE values: keyless authToken basic hmac jwt oauth openid
# mutualTLS other
set -uo pipefail

# The same publicly-reachable Tyk demo echo backend tyk-platform/up.sh
# already uses for its own seed API — real traffic through the seeded
# Gateway actually works, not just Dashboard/Portal metadata.
PROXY_TARGET="${PROXY_TARGET:-http://echo.tyk-demo.com:8080/trial}"

# build_apidef NAME LISTEN_PATH AUTH_TYPE — prints the api_definition JSON.
build_apidef() {
  local name="$1" listen_path="$2" auth_type="$3"
  local base
  base=$(jq -n \
    --arg name "$name" \
    --arg target "$PROXY_TARGET" \
    --arg listen_path "$listen_path" \
    '{
      name: $name,
      active: true,
      protocol: "http",
      proxy: { target_url: $target, listen_path: $listen_path, strip_listen_path: true },
      auth: { auth_header_name: "Authorization" },
      version_data: {
        not_versioned: true,
        versions: { Default: { name: "Default", use_extended_paths: true } }
      },
      use_keyless: false,
      use_standard_auth: false,
      use_basic_auth: false,
      enable_signature_checking: false,
      enable_jwt: false,
      use_oauth2: false,
      use_openid: false,
      use_mutual_tls_auth: false,
      enable_batch_request_support: true,
      enable_ip_whitelisting: false
    }')

  case "$auth_type" in
    keyless)
      base=$(jq '.use_keyless = true' <<<"$base") ;;
    authToken)
      base=$(jq '.use_standard_auth = true' <<<"$base") ;;
    basic)
      base=$(jq '.use_basic_auth = true' <<<"$base") ;;
    hmac)
      base=$(jq '.enable_signature_checking = true' <<<"$base") ;;
    jwt)
      # HMAC-signed JWT with an inline (base64) shared secret — enough for
      # the classic side to classify+expose this as "jwt" without an
      # external IdP; DCR/Keycloak-backed JWT is demonstrated separately by
      # the "oidc" seeded API against the stack's real Keycloak instance.
      base=$(jq '.enable_jwt = true
                 | .jwt_signing_method = "hmac"
                 | .jwt_source = "cG9jLXNlZWQtand0LXNoYXJlZC1zZWNyZXQ="
                 | .jwt_identity_base_field = "sub"
                 | .jwt_policy_field_name = "pol"' <<<"$base") ;;
    oauth)
      base=$(jq '.use_oauth2 = true
                 | .oauth_meta = {
                     allowed_access_types: ["client_credentials", "authorization_code"],
                     allowed_authorize_types: ["code"],
                     auth_login_redirect: ""
                   }' <<<"$base") ;;
    openid)
      # "keycloak" is this stack's OWN compose service name (docker-compose.yml),
      # reachable at that hostname from any other container on the same
      # compose network — NOT the shared tyk-platform stack's container name
      # (tyk-platform-keycloak-1), which doesn't exist in this isolated
      # stack's own network and would leave this issuer unreachable.
      base=$(jq '.use_openid = true
                 | .openid_options = {
                     providers: [ { issuer: "http://keycloak:8180/realms/master", client_ids: {} } ],
                     segregate_by_client: false
                   }' <<<"$base") ;;
    mutualTLS)
      base=$(jq '.use_mutual_tls_auth = true | .client_certificates = []' <<<"$base") ;;
    other)
      : # deliberately no auth flag at all — the classic "flagless API"
        # dead end MIGRATION_PLAN.md §5.6.6 and this tool's own
        # NeedsReviewAuthTypes flag as needing manual review before it can
        # migrate, reproduced here on purpose so the POC's own discovery
        # report shows that exact finding.
      ;;
    *)
      echo "build_apidef: unknown auth type '$auth_type'" >&2
      return 1
      ;;
  esac

  printf '%s' "$base"
}
