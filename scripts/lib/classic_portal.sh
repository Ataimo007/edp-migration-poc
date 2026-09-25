#!/usr/bin/env bash
# High-level wrappers over the Classic Dashboard + Classic Portal REST API
# (see mcp-specs/tyk-classic-portal-oas.yaml at the repo root for the full
# spec these are built from). Every function expects DASHBOARD_URL,
# ADMIN_SECRET, DASH_TOKEN and ORG_ID to already be exported by the caller
# (bootstrap.sh sets these up and seed.sh/reset.sh source its output).
set -uo pipefail

# ---- APIs -------------------------------------------------------------------

# create_api NAME LISTEN_PATH AUTH_TYPE — creates a Gateway API definition,
# prints its api_id.
create_api() {
  local name="$1" listen_path="$2" auth_type="$3"
  local apidef body resp api_id
  apidef=$(build_apidef "$name" "$listen_path" "$auth_type") || return 1
  body=$(jq -n --argjson apidef_json "$apidef" '{api_definition: $apidef_json}')
  resp=$(dash POST /api/apis "$body")
  api_id=$(json_get "$resp" '.ID // empty')
  if [[ -z "$api_id" || "$api_id" == "null" ]]; then
    err "create_api($name): unexpected response: $resp"
    return 1
  fi
  verbose "created API '$name' ($auth_type) -> $api_id"
  printf '%s' "$api_id"
}

# ---- Policies ---------------------------------------------------------------

# Three genuinely different rate/quota profiles, cycled across every
# seeded policy (see create_policy's $((_policy_seq % 3)) below) —
# deliberately NOT identical. edp-migrate's tier computation
# (AnalyzeCatalogueRange) collapses to a single "Standard" tier whenever
# every classic policy shares the same rate/quota (confirmed live), which
# would make a multi-tier migration demo look broken when it isn't; this
# is what a real customer's Bronze/Silver/Gold policy spread looks like.
#
# These are only the *fallback* values — seed.sh itself computes and
# reassigns all three arrays from its own --rate-min/--rate-max/
# --quota-min/--quota-max flags right after sourcing this file (plain
# global arrays, read fresh on every create_policy() call below, so a
# later reassignment is picked up with no changes needed here). Calling
# this file's own functions directly, without going through seed.sh,
# still works and falls back to these.
_TIER_RATE=(100  1000 10000)
_TIER_PER=(60   60   60)
_TIER_QUOTA=(1000 100000 -1)

# create_policy NAME API_ID AUTH_TYPE TIER_SEQ — creates a portal policy
# granting access to one API's Default version, prints the policy id.
# TIER_SEQ selects a rate/quota profile via TIER_SEQ % 3 from
# _TIER_RATE/_TIER_PER/_TIER_QUOTA above (see their comment) — passed in by
# the caller (a plain incrementing counter in seed.sh's own process),
# never tracked as mutable state in this file: create_policy is always
# invoked as `policy_id=$(create_policy ...)`, which runs it in a
# subshell, so any counter this function tried to maintain on its own
# would silently reset to its initial value on every single call.
create_policy() {
  local name="$1" api_id="$2" auth_type="$3" tier_seq="${4:-0}"
  local hmac_enabled=false
  [[ "$auth_type" == "hmac" ]] && hmac_enabled=true
  local tier=$(( tier_seq % 3 ))
  local body resp policy_id
  body=$(jq -n \
    --arg name "$name" \
    --arg org "$ORG_ID" \
    --arg api_id "$api_id" \
    --argjson hmac "$hmac_enabled" \
    --argjson rate "${_TIER_RATE[$tier]}" \
    --argjson per "${_TIER_PER[$tier]}" \
    --argjson quota "${_TIER_QUOTA[$tier]}" \
    '{
      name: $name,
      org_id: $org,
      active: true,
      rate: $rate,
      per: $per,
      quota_max: $quota,
      quota_renewal_rate: (if $quota == -1 then -1 else 86400 end),
      hmac_enabled: $hmac,
      access_rights: {
        ($api_id): { api_id: $api_id, api_name: "", versions: ["Default"], allowed_urls: [] }
      }
    }')
  resp=$(dash POST /api/portal/policies "$body")
  policy_id=$(json_get "$resp" '.Message // empty')
  if [[ -z "$policy_id" || "$policy_id" == "null" ]]; then
    err "create_policy($name): unexpected response: $resp"
    return 1
  fi
  verbose "created policy '$name' -> $policy_id"
  printf '%s' "$policy_id"
}

# ---- Catalogue --------------------------------------------------------------

# catalogue_add API_ID POLICY_ID NAME SHORT_DESC AUTH_TYPE — appends one
# entry to the org's API catalogue (GET-modify-PUT, since PUT only replaces
# the entries visible to the caller).
catalogue_add() {
  local api_id="$1" policy_id="$2" name="$3" short_desc="$4" auth_type="$5"
  local is_keyless=false
  [[ "$auth_type" == "keyless" ]] && is_keyless=true
  local current new_entry updated resp
  current=$(dash GET /api/portal/catalogue)
  # config.key_request_fields explicitly set to [] rather than left out —
  # the Dashboard's own ApiCatalogue.Config (PortalConfig struct,
  # tyk-analytics's portal_model_portal_config.go) leaves []string fields as
  # Go's nil-slice zero value when omitted, which serializes to JSON `null`,
  # not `[]`. Confirmed live: tyk-analytics-ui's catalogue details page
  # (data-handler/index.js's prepareUIValues -> arrayToEditableList) calls
  # `.map()` on config.key_request_fields with no null guard, so a catalogue
  # entry missing this field renders a genuinely blank detail page with
  # "TypeError: null is not an object (evaluating 'array.map')" in the
  # console — every entry this seed script creates hit this every time.
  # Diffed live against a catalogue entry created through the real
  # Dashboard UI to confirm this is the only field that matters here:
  # signup_fields is null there too (harmless — it's only read, with its
  # own `|| []` guard, by the separate org-level portal-configuration page,
  # never by this per-entry details page), so it's not set here.
  # oauth_usage_limit: -1 matches the real UI's own "unlimited" default
  # (its create-catalogue form's initial value) — the Go zero value (0)
  # this would otherwise get isn't a crash, just a wrong default that caps
  # OAuth client creation at zero for no reason.
  #
  # version: "v2" (tyk-analytics's own CatalogueVersion enum,
  # portal_model_api_catalogue.go: CatalogueV2 = "v2", CatalogueV1 = "" —
  # left out, this defaults to the "" / v1 legacy value). This one isn't
  # cosmetic: it's read server-side, not just by the Dashboard's own
  # catalogue editor. The end-user Classic Portal's own catalogue page
  # template (portal/templates/catalogue.html) branches its "Request an
  # API key" link on this exact field — {{if eq $apiDetail.Version ""}}
  # links to member/apis/{APIID}/request, else to
  # member/policies/{PolicyID}/request. Confirmed by reading every route
  # actually registered on the Classic Portal's own developer router
  # (server.go's securePortalDeveloperRouter): only the policies/:policyId
  # variant exists — the legacy apis/:apiID/request route this template
  # still emits for version=="" was removed from the router at some point
  # without updating the template to match, so a v1-style entry's own
  # "Request an API key" link 404s and falls through to the Classic
  # Portal's login page. A catalogue entry created through the real
  # Dashboard UI defaults to "v2" and never hits this; every entry this
  # seed script created was silently "v1" and broken until now.
  new_entry=$(jq -n \
    --arg name "$name" \
    --arg short "$short_desc" \
    --arg long "$short_desc — seeded for the edp-migration POC (auth type: $auth_type)." \
    --arg api_id "$api_id" \
    --arg policy_id "$policy_id" \
    --argjson keyless "$is_keyless" \
    '{ name: $name, short_description: $short, long_description: $long, show: true, api_id: $api_id, policy_id: $policy_id, is_keyless: $keyless, version: "v2", fields: {}, config: { key_request_fields: [], oauth_usage_limit: -1 } }')
  updated=$(jq --argjson e "$new_entry" '.apis = ((.apis // []) + [$e])' <<<"$current")
  resp=$(dash PUT /api/portal/catalogue "$updated")
  verbose "catalogue_add($name): $resp"
}

# ---- Developers -------------------------------------------------------------

# create_developer EMAIL FIRST LAST PASSWORD — prints the developer id.
create_developer() {
  local email="$1" first="$2" last="$3" password="$4"
  local body resp dev_id
  body=$(jq -n \
    --arg email "$email" --arg org "$ORG_ID" --arg pw "$password" \
    --arg first "$first" --arg last "$last" \
    '{ email: $email, org_id: $org, password: $pw, inactive: false, fields: { first_name: $first, last_name: $last } }')
  resp=$(dash POST /api/portal/developers "$body")
  dev_id=$(json_get "$resp" '.Message // empty')
  if [[ -z "$dev_id" || "$dev_id" == "null" ]]; then
    err "create_developer($email): unexpected response: $resp"
    return 1
  fi
  verbose "created developer '$email' -> $dev_id"
  printf '%s' "$dev_id"
}

# ---- Admin / console users --------------------------------------------------

# create_admin_user EMAIL FIRST LAST PASSWORD — a Dashboard admin/console
# user, distinct from a portal Developer (see edp-migrate's own
# distinction between the two in Migration Configure: "Admin Users → EDP
# Admins" is a separate, opt-in list from the public developer signups).
# Same two-step pattern bootstrap.sh uses for the very first admin:
# create via /admin/users/ (admin-secret-authenticated), then set the
# real password via POST /api/users/{id}/actions/reset — POST, not PUT,
# see bootstrap.sh's own comment for why that distinction is load-bearing.
# Prints the new user's id.
create_admin_user() {
  local email="$1" first="$2" last="$3" password="$4"
  local resp user_id reset_resp reset_status
  resp=$(dash_admin POST /admin/users/ "$(jq -n \
    --arg org "$ORG_ID" --arg first "$first" --arg last "$last" --arg email "$email" \
    '{ org_id: $org, first_name: $first, last_name: $last, email_address: $email, active: true, user_permissions: { IsAdmin: "admin" } }')")
  user_id=$(json_get "$resp" '.Meta.id // empty')
  if [[ -z "$user_id" || "$user_id" == "null" ]]; then
    err "create_admin_user($email): unexpected response: $resp"
    return 1
  fi
  reset_resp=$(curl -s -w '\n%{http_code}' -X POST "${DASHBOARD_URL}/api/users/${user_id}/actions/reset" \
    -H "Content-Type: application/json" -H "authorization: ${DASH_TOKEN}" \
    --data "$(jq -n --arg pw "$password" '{ new_password: $pw, user_permissions: { IsAdmin: "admin" } }')")
  reset_status="${reset_resp##*$'\n'}"
  if [[ "$reset_status" != "200" ]]; then
    err "create_admin_user($email): password set failed (HTTP $reset_status)"
    return 1
  fi
  verbose "created admin user '$email' -> $user_id"
  printf '%s' "$user_id"
}

# ---- Keys / key requests ----------------------------------------------------

# issue_key_for_developer DEV_ID POLICY_ID — admin-issues a key directly
# (bypasses the request/approve flow — used for the bulk of seeded keys so
# scale doesn't depend on how many pending requests were also asked for).
issue_key_for_developer() {
  local dev_id="$1" policy_id="$2"
  local body resp
  body=$(jq -n --arg pid "$policy_id" '{ policy_id: $pid }')
  resp=$(dash POST "/api/portal/developers/${dev_id}/keys" "$body")
  if [[ "$(json_get "$resp" '.Status // empty')" == "Error" ]]; then
    err "issue_key_for_developer($dev_id, $policy_id): $resp"
    return 1
  fi
  verbose "issue_key_for_developer($dev_id, $policy_id): $resp"
  printf '%s' "$resp"
}

# create_pending_request DEV_ID POLICY_ID API_ID — raises a developer key
# request left unapproved, so the seeded org has real work sitting in the
# "Key Requests" queue (and the migration tool's inventory picks it up as
# a pending Access Request). Prints the request id.
create_pending_request() {
  local dev_id="$1" policy_id="$2" api_id="$3"
  local body resp req_id
  body=$(jq -n --arg org "$ORG_ID" --arg by "$dev_id" --arg pid "$policy_id" --arg api "$api_id" \
    '{ org_id: $org, by_user: $by, for_api: $api, apply_policies: [$pid], approved: false }')
  resp=$(dash POST /api/portal/requests "$body")
  if [[ "$(json_get "$resp" '.Status // empty')" == "Error" ]]; then
    err "create_pending_request($dev_id): $resp"
    return 1
  fi
  req_id=$(json_get "$resp" '.Message // empty')
  if [[ -z "$req_id" || "$req_id" == "null" ]]; then
    err "create_pending_request($dev_id): unexpected response: $resp"
    return 1
  fi
  verbose "created pending request for $dev_id -> $req_id"
  printf '%s' "$req_id"
}

# ---- Org-level portal config (pages/menus/css/config) ---------------------
# Idempotent — safe to call every seed.sh run; skips anything that already
# exists rather than erroring or duplicating it.

ensure_menus() {
  local existing
  existing=$(dash GET /api/portal/menus)
  if [[ "$(json_get "$existing" '.id // empty')" != "" && "$(json_get "$existing" '.id // empty')" != "null" ]]; then
    verbose "portal menus already exist — skipping"
    return 0
  fi
  local body
  body=$(jq -n --arg org "$ORG_ID" '{
    org_id: $org, is_active: true,
    menus: { main: [ { title: "Catalogue", url: "/portal/catalogue" }, { title: "Documentation", url: "/portal/documentation" } ] }
  }')
  dash POST /api/portal/menus "$body" >/dev/null
  ok "created default portal menu"
}

ensure_css() {
  local existing
  existing=$(dash GET /api/portal/css)
  if [[ "$(json_get "$existing" '.id // empty')" != "" && "$(json_get "$existing" '.id // empty')" != "null" ]]; then
    verbose "portal CSS already exists — skipping"
    return 0
  fi
  local body
  body=$(jq -n --arg org "$ORG_ID" '{
    org_id: $org,
    page_css: "/* seeded by scripts/bootstrap.sh for the EDP Migration POC */\n.navbar-brand { font-weight: 600; }",
    email_css: ""
  }')
  dash POST /api/portal/css "$body" >/dev/null
  ok "created default portal CSS"
}

ensure_js() {
  local existing
  existing=$(dash GET /api/portal/js)
  if [[ "$(json_get "$existing" '.id // empty')" != "" && "$(json_get "$existing" '.id // empty')" != "null" ]]; then
    verbose "portal JS already exists — skipping"
    return 0
  fi
  local body
  body=$(jq -n --arg org "$ORG_ID" '{ org_id: $org, page_js: "// seeded by scripts/bootstrap.sh for the EDP Migration POC" }')
  dash POST /api/portal/js "$body" >/dev/null
  ok "created default portal JS"
}

# ensure_cname CNAME — sets the org's Portal CNAME (dashboard/
# portal_api_methods.go's SetOrgCNAME), e.g. "localhost:3000". Confirmed
# via source (dashboard/utils.go's GetPortalURL — what the Dashboard UI's
# own "Open Portal" link, window.PortalURL, is built from): without a
# registered CNAME, that falls back to this process's own externalIP()
# lookup instead, which inside a container resolves to an address the
# operator's own browser (outside Docker entirely) can't reach at all —
# a link that looks fine but silently goes nowhere. This is exactly the
# step the reference tyk-pro-docker-demo/scripts/portal_bootstrap.sh does
# (its own "Set Portal CNAME" call) that this project's own bootstrap.sh
# was missing.
ensure_cname() {
  local cname="$1" resp
  resp=$(dash PUT /api/portal/cname "$(jq -n --arg cname "$cname" '{CNAME: $cname}')")
  if [[ "$(json_get "$resp" '.Status // empty')" != "OK" ]]; then
    err "setting portal CNAME to '$cname' failed: $resp"
    return 1
  fi
  verbose "portal CNAME set to '$cname'"
}

ensure_portal_config() {
  local existing
  existing=$(dash GET /api/portal/configuration)
  if [[ "$(json_get "$existing" '.id // empty')" != "" && "$(json_get "$existing" '.id // empty')" != "null" ]]; then
    verbose "portal configuration already exists — skipping"
    return 0
  fi
  dash POST /api/portal/configuration '{}' >/dev/null
  ok "created default portal configuration"
}

# ensure_portal_routes_live — works around a confirmed bug in
# tyk-analytics's own SetOrgCNAME handler (dashboard/portal_api_methods.go):
# on a CNAME change it calls GenerateRoutes() to "reload the URL structure"
# but discards the *mux.Router it returns, so this only ever has an effect
# on the very first call, at process startup (server.go's own
# `http.Serve(dashboardServer, GenerateRoutes())`) — every later call
# (including the one this org's own CNAME PUT just triggered) builds a
# brand new router graph that's immediately thrown away, never wired into
# the live listener. Since bootstrap.sh always creates the org (and hence
# sets up its CNAME) *after* tyk-dashboard is already running, the
# container's live routes are permanently stuck reflecting "zero
# organisations exist yet" — no Classic Portal route is registered at any
# path, with or without an org-ID prefix — until tyk-dashboard itself is
# restarted with the org already in Postgres. Confirmed live: every
# /portal/* path 200s with the exact same Dashboard login SPA HTML that a
# nonexistent path also returns, until a restart, after which /portal/
# correctly serves the real Classic Portal homepage.
#
# Detects this by checking for a string unique to the real Classic Portal
# HTML (its own portal-assets/ stylesheet links — the Dashboard SPA has no
# such thing) rather than assuming the state based on whether this is a
# fresh bootstrap or the "already bootstrapped" shortcut path — either one
# can be stuck on a stale, org-less route table (e.g. a plain container
# restart via `docker compose restart` with the DB already populated
# doesn't hit this, but a from-scratch `docker compose up -d` always does).
ensure_portal_routes_live() {
  local sample
  sample=$(curl -s --max-time 5 "${DASHBOARD_URL}/portal/" || true)
  if [[ "$sample" == *"portal-assets"* ]]; then
    verbose "Classic Portal routes already live — skipping tyk-dashboard restart"
    return 0
  fi
  warn "Classic Portal isn't being served yet (tyk-analytics only wires up its routes at tyk-dashboard's own startup, see this function's own comment) — restarting the tyk-dashboard container so it picks up this org"
  docker compose restart tyk-dashboard >/dev/null || { err "docker compose restart tyk-dashboard failed"; return 1; }
  wait_for_http "${DASHBOARD_URL}/hello" 90 2 || { err "tyk-dashboard never came back up after restarting"; return 1; }
  sample=$(curl -s --max-time 5 "${DASHBOARD_URL}/portal/" || true)
  if [[ "$sample" != *"portal-assets"* ]]; then
    err "restarted tyk-dashboard but the Classic Portal still isn't being served at ${DASHBOARD_URL}/portal/ — something else is wrong"
    return 1
  fi
  ok "Classic Portal is now live at ${DASHBOARD_URL}/portal/"
}

ensure_homepage() {
  local existing
  existing=$(dash GET /api/portal/pages)
  if jq -e '.Data // [] | any(.is_homepage == true)' <<<"$existing" >/dev/null 2>&1; then
    verbose "portal homepage already exists — skipping"
    return 0
  fi
  local body
  body=$(jq -n --arg title "$SEED_PREFIX EDP Migration POC" '{
    is_homepage: true, template_name: "", title: $title, slug: "/",
    fields: {
      JumboCTATitle: "EDP Migration POC",
      SubHeading: "A seeded Classic Developer Portal, ready to migrate.",
      JumboCTALink: "#catalogue", JumboCTALinkTitle: "Browse the catalogue",
      PanelOneTitle: "Seeded for a purpose", PanelOneContent: "Every developer, API and key on this portal was generated by scripts/seed.sh so you can rehearse a real migration.",
      PanelOneLink: "#", PanelOneLinkTitle: "Learn more",
      PanelTwoTitle: "Vary the scale", PanelTwoContent: "Re-run seed.sh with --scale large or explicit counts to stress-test the migration tool.",
      PanelTwoLink: "#", PanelTwoLinkTitle: "Learn more",
      PanelThreeTitle: "Then migrate", PanelThreeContent: "Point edp-migrate at this Dashboard and this data becomes your rehearsal migration.",
      PanelThreeLink: "#", PanelThreeLinkTitle: "Learn more"
    }
  }')
  dash POST /api/portal/pages "$body" >/dev/null
  ok "created portal homepage"
}
