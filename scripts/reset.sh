#!/usr/bin/env bash
# reset.sh — removes everything scripts/seed.sh has ever created on the
# CLASSIC PORTAL side only (every developer, API, and policy recorded in
# .seed-state/*.jsonl), leaving the org, admin user, and portal config from
# bootstrap.sh intact so you can reseed immediately.
#
# IMPORTANT: if you've also run edp-migrate against this data (inventory
# is fine; plan/execute is not), use --full instead, every time. EDP has a
# confirmed live bug where deleting a migrated Product/Plan whose
# underlying classic Policy is already gone 404s and leaves the EDP row
# permanently orphaned — there is no reliable way to clean EDP's side
# incrementally. This script only ever touches the Classic Dashboard, so
# after a migrate cycle it cannot clean EDP's data even if you wanted it
# to. Between full seed -> migrate -> demo cycles, always prefer:
#
#   scripts/reset.sh --full
#
# over this script's default (Classic-Portal-only) mode.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

source scripts/lib/common.sh

if [[ "${1:-}" == "--full" ]]; then
  warn "docker compose down -v: this deletes every container AND volume (Postgres/Redis/Portal data, EDP's database, the edp-migrate /data volume) — irreversible, and the only reliable way to also clear anything already migrated into EDP."
  read -r -p "Type \"yes\" to proceed: " confirm
  [[ "$confirm" == "yes" ]] || { info "aborted — nothing was changed"; exit 0; }
  docker compose down -v
  rm -f .runtime.env
  rm -rf .seed-state
  ok "stack torn down and all seed state cleared"
  exit 0
fi

RUNTIME_FILE="$(pwd)/.runtime.env"
[[ -f "$RUNTIME_FILE" ]] || die "no $RUNTIME_FILE found — nothing to reset (run scripts/bootstrap.sh first if you want a fresh org)"
# shellcheck source=/dev/null
source "$RUNTIME_FILE"

shopt -s nullglob
files=(.seed-state/*.jsonl)
if [[ ${#files[@]} -eq 0 ]]; then
  info "no .seed-state/*.jsonl files found — nothing seed.sh created is tracked, nothing to delete"
  info "(run with --full to tear down the whole docker compose stack instead)"
  exit 0
fi

warn "this only cleans the Classic Dashboard side. If you've already run 'edp-migrate execute' against this data, this will NOT clean up EDP's database — use --full instead (see this script's header comment)."

dev_ids=() policy_ids=() api_ids=() request_ids=()
for f in "${files[@]}"; do
  while IFS=$'\t' read -r type id; do
    case "$type" in
      developer) dev_ids+=("$id") ;;
      policy)    policy_ids+=("$id") ;;
      api)       api_ids+=("$id") ;;
      request)   request_ids+=("$id") ;;
    esac
  done < <(jq -r '[.type, .id] | @tsv' "$f")
done

info "deleting ${#dev_ids[@]} developer(s), ${#request_ids[@]} pending request(s), ${#policy_ids[@]} policy(ies), ${#api_ids[@]} API(s) recorded by previous seed.sh runs..."

# Deleted first, and independently of developers below: a KeyRequest
# record outlives the developer who raised it (confirmed live — deleting
# a developer does not cascade-delete their still-pending requests), so
# without this an old pending request stays in the Dashboard's "Key
# Requests" queue forever, orphaned from any real developer.
for id in "${request_ids[@]}"; do
  dash DELETE "/api/portal/requests/${id}" >/dev/null
done
ok "pending requests deleted"

# delete_all METHOD PATH_PREFIX ID... — DELETEs each id under
# PATH_PREFIX, tracking (not silently swallowing) any that fail — the
# Classic Dashboard is confirmed to sometimes refuse to delete a
# developer who still has issued keys ("Failure deleting key, please
# contact your administrator", live) — this only affects reset.sh's own
# best-effort cleanup accounting, not the seed data's usability.
failed_ids=()
delete_all() {
  local path_prefix="$1"; shift
  local id resp status
  for id in "$@"; do
    resp=$(dash DELETE "${path_prefix}${id}")
    status=$(json_get "$resp" '.Status // empty')
    [[ "$status" == "Error" ]] && failed_ids+=("${path_prefix}${id}: $(json_get "$resp" '.Message // "unknown error"')")
  done
}

delete_all "/api/portal/developers/" "${dev_ids[@]}"
ok "developers: delete attempted for ${#dev_ids[@]}"

delete_all "/api/portal/policies/" "${policy_ids[@]}"
ok "policies: delete attempted for ${#policy_ids[@]}"

delete_all "/api/apis/" "${api_ids[@]}"
ok "APIs: delete attempted for ${#api_ids[@]}"

if [[ ${#failed_ids[@]} -gt 0 ]]; then
  warn "${#failed_ids[@]} deletion(s) failed and were left in place:"
  for f in "${failed_ids[@]}"; do warn "  - $f"; done
  warn "this is exactly the kind of incremental-cleanup gap --full avoids — prefer it between demo cycles."
fi

# The catalogue only ever grows via GET-modify-PUT (classic_portal.sh's
# catalogue_add) — easiest correct cleanup is to drop every entry whose
# api_id was one we just deleted, in one PUT, rather than trying to
# reverse each catalogue_add individually.
current=$(dash GET /api/portal/catalogue)
deleted_apis_json=$(printf '%s\n' "${api_ids[@]}" | jq -R . | jq -s .)
updated=$(jq --argjson deleted "$deleted_apis_json" '.apis = ((.apis // []) | map(select(([.api_id] | inside($deleted)) | not)))' <<<"$current")
dash PUT /api/portal/catalogue "$updated" >/dev/null
ok "catalogue entries pruned"

rm -f "${files[@]}"
ok "cleared .seed-state/ — reset complete. Run scripts/seed.sh again whenever you like."
