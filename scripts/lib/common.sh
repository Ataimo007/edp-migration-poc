#!/usr/bin/env bash
# Shared helpers for every script under poc-environment/scripts/.
# Sourced, never executed directly.

set -uo pipefail

# ---- logging --------------------------------------------------------------

_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_blue=$'\033[34m'

log()  { printf '%s\n' "$*" >&2; }
info() { printf '%s[*]%s %s\n' "$_c_blue" "$_c_reset" "$*" >&2; }
ok()   { printf '%s[OK]%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }
verbose() { [[ "${VERBOSE:-0}" == "1" ]] && printf '%s    %s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; return 0; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c (see README.md prerequisites)"
  done
}

# ---- waiting on HTTP services ---------------------------------------------

# wait_for_http URL [max_attempts] [sleep_seconds]
wait_for_http() {
  local url="$1" max="${2:-60}" delay="${3:-2}" attempt=0 code="000"
  info "waiting for $url ..."
  while (( attempt < max )); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" || echo "000")
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
      ok "$url is up (HTTP $code)"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "$delay"
  done
  err "$url did not come up after $((max * delay))s (last HTTP code: $code)"
  return 1
}

# ---- Dashboard API helpers -------------------------------------------------
# DASHBOARD_URL/ADMIN_SECRET/DASH_TOKEN are read from the environment by
# callers — kept out of this file so it stays a pure transport layer.

# dash_admin METHOD PATH [JSON_BODY] — the Dashboard's /admin/ API
# (org/user bootstrap), authenticated with the admin secret
# (TYK_DB_ADMINSECRET, confs/tyk_analytics.env).
dash_admin() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -X "$method" "${DASHBOARD_URL}${path}" -H "admin-auth: ${ADMIN_SECRET}" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}"
}

# dash METHOD PATH [JSON_BODY] — authenticated with a regular user/org API
# token (DASH_TOKEN), used for every /api/... and /api/portal/... call.
dash() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-s -X "$method" "${DASHBOARD_URL}${path}" -H "Authorization: ${DASH_TOKEN}" -H "Content-Type: application/json")
  [[ -n "$body" ]] && args+=(--data "$body")
  curl "${args[@]}"
}

json_get() { # json_get '<json>' '<jq filter>'
  printf '%s' "$1" | jq -r "$2"
}

# ---- deterministic-ish random data ----------------------------------------
# Not cryptographically random — just enough spread to look like real
# tenants/developers without needing an external faker dependency.

_first_names=(Sarah Raj Amara Liam Noor Diego Yuki Priya Owen Fatima Mateo Ingrid Kwame Elena Tariq Nadia Felix Ayaan Sofia Marcus Hana Leo Zainab Oscar Mei Idris Chloe Viktor Amina Ravi)
_last_names=(Chen Patel Osei Murphy Haddad Torres Tanaka Iyer Brooks Rahman Silva Larsen Boateng Farouk Kowalski Malik Novak Khan Ramirez Whitfield Suzuki Fontaine Diallo Reyes Zhang Bello Bennett Petrov Njoku Deshmukh)
_companies=(Acme Skyline Bluewave Nimbus Ironclad Solstice Vantage Redwood Zenith Orbital Meridian Fathom Cobalt Lumen Anchor Driftwood Pinnacle Cascade Beacon Northstar)
_domains=(cloud tech labs systems analytics works digital io dev)

rand_pick() { local -n arr="$1"; echo "${arr[$((RANDOM % ${#arr[@]}))]}"; }

# seeded_person SUFFIX — prints "FirstName<TAB>LastName<TAB>email" for a
# deterministic-shape, unique-per-suffix fake developer.
seeded_person() {
  local suffix="$1"
  local fn ln company domain email
  fn=$(rand_pick _first_names); ln=$(rand_pick _last_names)
  company=$(rand_pick _companies); domain=$(rand_pick _domains)
  email=$(printf '%s.%s%s@%s%s.example-poc.dev' "${fn,,}" "${ln,,}" "$suffix" "${company,,}" "$suffix")
  printf '%s\t%s\t%s\n' "$fn" "$ln" "$email"
}

# Every resource this toolkit creates carries this literal prefix in its
# name/title — reset.sh finds everything to delete by filtering on it, and a
# human skimming the Dashboard UI can immediately tell seeded data apart
# from anything created by hand.
SEED_PREFIX="[poc-seed]"
