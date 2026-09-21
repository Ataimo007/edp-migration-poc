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
  new_entry=$(jq -n \
    --arg name "$name" \
    --arg short "$short_desc" \
    --arg long "$short_desc — seeded for the edp-migration POC (auth type: $auth_type)." \
    --arg api_id "$api_id" \
    --arg policy_id "$policy_id" \
    --argjson keyless "$is_keyless" \
    '{ name: $name, short_description: $short, long_description: $long, show: true, api_id: $api_id, policy_id: $policy_id, is_keyless: $keyless, fields: {} }')
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
