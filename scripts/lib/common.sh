#!/usr/bin/env bash
# Shared helpers for every script under poc-environment/scripts/.
# Sourced, never executed directly.

set -uo pipefail

# Every caller of this file has already `cd`'d to the repo root
# (bootstrap.sh/seed.sh/reset.sh's own first line), so this is always
# poc-environment/.env — the same file `docker compose up` itself reads
# for host-port overrides (DASHBOARD_HOST_PORT etc.). Compose reads it
# automatically for the compose file's own variable substitution, but a
# plain bash script run directly (or invoked as a subprocess from
# up.sh) has no such thing happen for it automatically — without this,
# bootstrap.sh/seed.sh/reset.sh silently ignored any port customization
# in .env and fell back to the hardcoded default (13000 etc.), which,
# confirmed live, can mean bootstrapping against a completely different,
# unrelated Dashboard that happens to already be listening on that
# default port rather than this stack's own (intentionally
# non-default-ported) one.
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

# ---- logging --------------------------------------------------------------

_c_reset=$'\033[0m'; _c_dim=$'\033[2m'; _c_red=$'\033[31m'; _c_green=$'\033[32m'; _c_yellow=$'\033[33m'; _c_blue=$'\033[34m'

# _progress_bar_active tracks whether progress_bar (below) has the cursor
# sitting mid-line, redrawing in place — every other log line here checks
# it first and, if set, emits a newline to move off that line before
# printing its own, so a warn()/err() firing mid-progress-bar never gets
# mashed onto the end of the bar's own text instead of starting cleanly at
# column 0.
_progress_bar_active=0
_progress_bar_clear_if_active() {
  if [[ "$_progress_bar_active" == "1" ]]; then
    printf '\n' >&2
    _progress_bar_active=0
  fi
}

log()  { _progress_bar_clear_if_active; printf '%s\n' "$*" >&2; }
info() { _progress_bar_clear_if_active; printf '%s[*]%s %s\n' "$_c_blue" "$_c_reset" "$*" >&2; }
ok()   { _progress_bar_clear_if_active; printf '%s[OK]%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
warn() { _progress_bar_clear_if_active; printf '%s[!]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
err()  { _progress_bar_clear_if_active; printf '%s[x]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }
verbose() { [[ "${VERBOSE:-0}" == "1" ]] && { _progress_bar_clear_if_active; printf '%s    %s%s\n' "$_c_dim" "$*" "$_c_reset" >&2; }; return 0; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c (see README.md prerequisites)"
  done
}

# ---- live progress bar ------------------------------------------------------
# A long seed.sh run used to only ever print one "ok" line per resource —
# fine at --scale small, unreadable scrollback at medium/large with nothing
# to glance at for "is this stuck or just slow". progress_bar redraws a
# single line in place instead (a bar + percentage + a caption naming
# whatever operation just started), and progress_bar_done moves off that
# line once the run reaches its last step so real log output afterward
# (the final summary, a die()) starts on its own fresh line.
#
# Skipped entirely under --verbose: that mode already prints every API
# call/response as its own permanent line, and a redrawing bar interleaved
# with that would just get garbled rather than adding anything.
_progress_bar_width=30
progress_bar() { # progress_bar CURRENT TOTAL LABEL
  [[ "${VERBOSE:-0}" == "1" ]] && return
  local current="$1" total="$2" label="$3"
  (( total <= 0 )) && total=1
  (( current > total )) && current=$total
  local filled=$(( current * _progress_bar_width / total ))
  local empty=$(( _progress_bar_width - filled ))
  local pct=$(( current * 100 / total ))
  local bar
  bar="$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' "$empty" '' | tr ' ' '-')"
  # \r returns to column 0 without a newline (so the next call overwrites
  # this same line); \033[K clears to end of line so a shorter label never
  # leaves stray characters from a longer previous one trailing after it.
  printf '\r\033[K%s[%s]%s %3d%% (%d/%d) %s' "$_c_blue" "$bar" "$_c_reset" "$pct" "$current" "$total" "$label" >&2
  _progress_bar_active=1
}

# progress_bar_done — call once after the last progress_bar update.
progress_bar_done() {
  [[ "${VERBOSE:-0}" == "1" ]] && return
  printf '\n' >&2
  _progress_bar_active=0
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

# gen_password — a random per-account password, real enough to matter
# once it's recorded in a seed-state file someone might actually use to
# log in and poke around, not just a shared placeholder every account
# reuses. Guarantees at least one digit and one uppercase letter so it
# clears typical "must contain a number/uppercase" signup validation.
gen_password() {
  printf 'Px%s9!' "$(openssl rand -base64 9 | tr -dc 'A-Za-z0-9' | head -c 10)"
}

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
