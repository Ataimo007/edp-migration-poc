#!/usr/bin/env bash
# seed.sh — populates the Classic Developer Portal (APIs, policies,
# catalogue entries, developers, keys, pending key requests) so there's a
# realistic, variably-sized migration source for edp-migrate to work
# against. Requires scripts/bootstrap.sh to have run first.
#
# Usage: scripts/seed.sh [--scale small|medium|large] [options]
#        scripts/seed.sh --help
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

source scripts/lib/common.sh
source scripts/lib/apidef.sh
source scripts/lib/classic_portal.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [--scale small|medium|large] [options]

Scale presets (developers / APIs per auth type / keys per developer / pending requests):
  small   (default)  20  / 1 / 2 / 5
  medium              100 / 2 / 3 / 15
  large               500 / 3 / 5 / 50

Options (override individual scale-preset values):
  --scale NAME              small | medium | large           (default: small)
  --developers N             number of developer accounts to create
  --apis-per-type N          how many API+Policy+Catalogue trios per auth type
  --keys-per-developer N     keys issued per developer (beyond any pending request)
  --pending-requests N       how many developers get an unapproved pending key request instead
  --admin-users N            total Dashboard admin/console users, bootstrap.sh's own first
                              admin counted as #1 (default: 3 — creates 2 more: "POC Admin2",
                              "POC Admin3", each with its own random password)
  --auth-types LIST          comma-separated subset of:
                              keyless,token,basic,hmac,jwt,oauth,openid,mutualTLS,other
                              ("token" is an alias for authToken)
                              (default: all of them)
  --run-suffix STR           uniqueness suffix for names/emails this run (default: random)
  --state-format yaml|json   .seed-state/ output format (default: yaml)
  --no-detailed-recording    don't enable full request/response body capture
                              (enable_detailed_recording) on seeded APIs — on
                              by default, since seeing actual traffic in the
                              Dashboard's Activity Log is normally the point
                              of a POC/test stack like this one
  --rate-min N               lowest-tier Policy's rate limit, requests/60s
                              (default: 100)
  --rate-max N               highest-tier Policy's rate limit, requests/60s
                              (default: 10000). The middle tier is always
                              the geometric mean of the two.
  --quota-min N               lowest-tier Policy's quota, requests per 24h
                              (default: 1000000 — high enough that even a
                              load-test run (scripts/load-test/, default
                              0.5 rps/worker) can hammer a low-tier key
                              continuously for a full day without
                              exhausting it; confirmed live the old
                              default of 1000 didn't survive even 6h)
  --quota-max N               highest-tier Policy's quota (default: -1,
                              Tyk's own convention for "unlimited" — pass
                              a real number instead to make even the top
                              tier finite). The middle tier is always the
                              geometric mean of the two, unless this is -1,
                              in which case it's --quota-min x10.
  --dry-run                  print what would be created; make no API calls
  -v, --verbose               print every API call and response
  --validate-only            check every flag/value above is valid and exit
                              0 immediately — no bootstrap.sh check, no API
                              calls, nothing written. This is what ./up.sh
                              itself runs first, before bringing up any part
                              of the stack, so a typo like --rubish is
                              caught and reported immediately instead of
                              only failing once seed.sh actually starts (by
                              which point the whole stack is already up).
                              Useful directly too, to lint a long command
                              before running it for real.
  -h, --help                  this help
EOF
}

SCALE="small"
DEVELOPERS="" APIS_PER_TYPE="" KEYS_PER_DEV="" PENDING_REQUESTS="" ADMIN_USERS=""
AUTH_TYPES="keyless,authToken,basic,hmac,jwt,oauth,openid,mutualTLS,other"
# Seconds since epoch + 3 random digits — practically never repeats
# across two separate invocations (confirmed live this was a real,
# reproducible problem with the previous plain "$((RANDOM % 100000))":
# bash's RANDOM only has 32768 distinct values and reseeds from a fairly
# weak default source, so two runs close together in time could and did
# draw the exact same value, producing genuinely duplicate-looking
# API/policy/catalogue names across runs — Tyk itself never enforces name
# uniqueness, so nothing else would have caught it).
RUN_SUFFIX="$(date +%s)$((RANDOM % 1000))"
STATE_FORMAT="yaml"
DRY_RUN=0
# Exported so lib/apidef.sh's own DETAILED_RECORDING="${DETAILED_RECORDING:-true}"
# picks up a --no-detailed-recording override without build_apidef needing
# a fourth parameter threaded through every call site.
export DETAILED_RECORDING=true
RATE_MIN="" RATE_MAX="" QUOTA_MIN="" QUOTA_MAX=""
VALIDATE_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2 ;;
    --developers) DEVELOPERS="$2"; shift 2 ;;
    --apis-per-type) APIS_PER_TYPE="$2"; shift 2 ;;
    --keys-per-developer) KEYS_PER_DEV="$2"; shift 2 ;;
    --pending-requests) PENDING_REQUESTS="$2"; shift 2 ;;
    --admin-users) ADMIN_USERS="$2"; shift 2 ;;
    --auth-types) AUTH_TYPES="$2"; shift 2 ;;
    --no-detailed-recording) DETAILED_RECORDING=false; shift ;;
    --rate-min) RATE_MIN="$2"; shift 2 ;;
    --rate-max) RATE_MAX="$2"; shift 2 ;;
    --quota-min) QUOTA_MIN="$2"; shift 2 ;;
    --quota-max) QUOTA_MAX="$2"; shift 2 ;;
    --run-suffix) RUN_SUFFIX="$2"; shift 2 ;;
    --state-format) STATE_FORMAT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --validate-only) VALIDATE_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done
ADMIN_USERS="${ADMIN_USERS:-3}"
RATE_MIN="${RATE_MIN:-100}"
RATE_MAX="${RATE_MAX:-10000}"
QUOTA_MIN="${QUOTA_MIN:-1000000}"
QUOTA_MAX="${QUOTA_MAX:--1}"

require_cmd awk
[[ "$RATE_MIN" =~ ^[0-9]+$ && "$RATE_MAX" =~ ^[0-9]+$ ]] || die "--rate-min/--rate-max must be positive integers"
(( RATE_MIN <= RATE_MAX )) || die "--rate-min ($RATE_MIN) must be <= --rate-max ($RATE_MAX)"
[[ "$QUOTA_MIN" =~ ^[0-9]+$ ]] || die "--quota-min must be a positive integer"
[[ "$QUOTA_MAX" =~ ^-?[0-9]+$ ]] || die "--quota-max must be an integer (-1 for unlimited)"
[[ "$QUOTA_MAX" == "-1" || "$QUOTA_MIN" -le "$QUOTA_MAX" ]] || die "--quota-min ($QUOTA_MIN) must be <= --quota-max ($QUOTA_MAX), or --quota-max -1 for unlimited"

# Overrides lib/classic_portal.sh's own _TIER_RATE/_TIER_PER/_TIER_QUOTA
# fallback arrays with the actual --rate-min/--rate-max/--quota-min/
# --quota-max bounds — create_policy() (that file) reads these three
# global arrays fresh on every call, so reassigning them here, after
# sourcing that file, is picked up with no changes needed there. The
# middle tier is always the geometric mean of the two bounds (matching
# the original hardcoded 100/1000/10000 and 1000/100000 relationships,
# both already exactly geometric with a common ratio of 10) — except
# quota's middle tier when quota-max is -1 (unlimited): a geometric mean
# with infinity is meaningless, so that case just steps up 10x from
# quota-min instead.
_TIER_RATE=("$RATE_MIN" "$(awk -v a="$RATE_MIN" -v b="$RATE_MAX" 'BEGIN{printf "%d", sqrt(a*b)}')" "$RATE_MAX")
_TIER_PER=(60 60 60)
if [[ "$QUOTA_MAX" == "-1" ]]; then
  _TIER_QUOTA=("$QUOTA_MIN" "$((QUOTA_MIN * 10))" -1)
else
  _TIER_QUOTA=("$QUOTA_MIN" "$(awk -v a="$QUOTA_MIN" -v b="$QUOTA_MAX" 'BEGIN{printf "%d", sqrt(a*b)}')" "$QUOTA_MAX")
fi

case "$STATE_FORMAT" in
  yaml|json) ;;
  *) die "unknown --state-format '$STATE_FORMAT' (want yaml|json)" ;;
esac
require_cmd yq

case "$SCALE" in
  small)  d_def=20;  a_def=1; k_def=2; p_def=5 ;;
  medium) d_def=100; a_def=2; k_def=3; p_def=15 ;;
  large)  d_def=500; a_def=3; k_def=5; p_def=50 ;;
  *) die "unknown --scale '$SCALE' (want small|medium|large)" ;;
esac
DEVELOPERS="${DEVELOPERS:-$d_def}"
APIS_PER_TYPE="${APIS_PER_TYPE:-$a_def}"
KEYS_PER_DEV="${KEYS_PER_DEV:-$k_def}"
PENDING_REQUESTS="${PENDING_REQUESTS:-$p_def}"

# Every flag/value above is validated by this point — nothing below this
# line runs for --validate-only. Deliberately ahead of the DASH_TOKEN/
# .runtime.env check right after: this is the whole reason that check (and
# everything else needing a live, bootstrapped stack) isn't at the top of
# the file any more. ./up.sh runs this exact mode, on the host, before
# bringing up any part of the stack — an unknown flag like --rubish (or an
# out-of-range --rate-min/--quota-max, an unknown --scale/--state-format)
# is now caught immediately, instead of only failing once seed.sh actually
# starts running for real, by which point the whole stack (and bootstrap.sh)
# already ran for nothing.
if [[ $VALIDATE_ONLY -eq 1 ]]; then
  exit 0
fi

# Running as the "seed" compose service (scripts/seed/Dockerfile) rather
# than directly on the host? DASH_TOKEN et al already arrive as real
# process environment variables (docker-compose.yml's own env_file:
# .runtime.env for that service) before this script ever starts, so
# there's no .runtime.env *file* to find inside the container at all —
# only read/require one when the environment doesn't already have what
# bootstrap.sh's own output provides.
if [[ -z "${DASH_TOKEN:-}" ]]; then
  RUNTIME_FILE="$(pwd)/.runtime.env"
  [[ -f "$RUNTIME_FILE" ]] || die "no $RUNTIME_FILE found and no DASH_TOKEN in the environment — run scripts/bootstrap.sh first"
  # shellcheck source=/dev/null
  source "$RUNTIME_FILE"
fi

# The real, externally-callable base URL for every seeded API — common.sh
# already sourced .env (GATEWAY_HOST_PORT et al) as plain env vars.
# Recorded per-API below (alongside internal_url) so anything with a
# working curl and this stack's own host ports can call these APIs
# directly, no separate lookup needed.
GATEWAY_URL="http://localhost:${GATEWAY_HOST_PORT:-8080}"
# The *internal* docker-network address for the same Gateway — always
# tyk-gateway:8080 regardless of GATEWAY_HOST_PORT/--dev-ports, since a
# host-side port mapping doesn't apply to container-to-container traffic
# at all (same reasoning as confs/edp-migrate.env's own internal
# addresses). This is what scripts/load-test/'s own "locust" compose
# service actually uses — it runs as a container on this same "tyk"
# network, so it should never depend on (or be affected by) whatever this
# run's host ports happen to be.
GATEWAY_INTERNAL_URL="http://tyk-gateway:8080"

IFS=',' read -ra TYPES <<<"$AUTH_TYPES"
# "token" is a friendlier alias for the classic auth type's real name.
for i in "${!TYPES[@]}"; do
  [[ "${TYPES[$i]}" == "token" ]] && TYPES[$i]="authToken"
done

info "scale=$SCALE developers=$DEVELOPERS apis-per-type=$APIS_PER_TYPE keys-per-developer=$KEYS_PER_DEV pending-requests=$PENDING_REQUESTS admin-users=$ADMIN_USERS auth-types=${TYPES[*]}"
[[ $DRY_RUN -eq 1 ]] && warn "--dry-run: no API calls will be made"

# TOTAL_STEPS/STEP back the live progress_bar (lib/common.sh) below — one
# step per additional admin user, per API/Policy/Catalogue trio, and per
# developer (a developer's own keys/pending-request aren't separately
# counted — the bar's caption names which developer is in progress, not
# every individual key issued for them).
admins_to_create=$(( ADMIN_USERS > 1 ? ADMIN_USERS - 1 : 0 ))
TOTAL_STEPS=$(( admins_to_create + ${#TYPES[@]} * APIS_PER_TYPE + DEVELOPERS ))
STEP=0

mkdir -p .seed-state
# A single JSON document, rewritten incrementally via jq as things are
# created (reset.sh's --full aside, this file is the only record of what
# a run made) — converted to the chosen --state-format (yaml by default)
# only once, at the very end, since yq/jq round-trip cleanly but there's
# no reason to reformat on every single append.
STATE_TMP=".seed-state/.run-${RUN_SUFFIX}.json.tmp"
[[ $DRY_RUN -eq 0 ]] && echo '{"admin_users":[],"apis":[],"policies":[],"developers":[]}' > "$STATE_TMP"

jq_update() { # jq_update FILTER [--arg name value]...
  local filter="$1"; shift
  jq "$@" "$filter" "$STATE_TMP" > "${STATE_TMP}.new" && mv "${STATE_TMP}.new" "$STATE_TMP"
}
# record_admin_user ID EMAIL PASSWORD — the Dashboard admin/console login
# itself (bootstrap.sh's original admin included, as #1 — see the
# --admin-users section below), recorded here so this one file is the
# single place to find every credential a seeded stack has, not just the
# ones seed.sh itself created this run.
record_admin_user() {
  jq_update '.admin_users += [{"id":$id,"email":$email,"password":$pw}]' \
    --arg id "$1" --arg email "$2" --arg pw "$3"
}
record_api() { # id name auth_type listen_path
  jq_update '.apis += [{"id":$id,"name":$name,"auth_type":$auth_type,"listen_path":$path,"url":$url,"internal_url":$iurl}]' \
    --arg id "$1" --arg name "$2" --arg auth_type "$3" --arg path "$4" \
    --arg url "${GATEWAY_URL}${4}" --arg iurl "${GATEWAY_INTERNAL_URL}${4}"
}
record_policy() { # id name
  jq_update '.policies += [{"id":$id,"name":$name}]' --arg id "$1" --arg name "$2"
}
# record_developer ID EMAIL PASSWORD — the real password create_developer
# just signed this account up with (each developer gets its own random
# one, gen_password() — no more one shared literal every account reused).
record_developer() {
  jq_update '.developers += [{"id":$id,"email":$email,"password":$pw,"keys":[],"pending_requests":[]}]' \
    --arg id "$1" --arg email "$2" --arg pw "$3"
}
# record_key DEV_ID RAW_KEY API_ID [PASSWORD] — RAW_KEY is the actual
# issued credential (for Basic Auth specifically, it's the *username*;
# PASSWORD holds the real password — an easy-to-get-backwards gotcha, see
# docs/SEEDING_GUIDE.md). There's no separate cryptographic hash to
# record here: the Dashboard's own key-issuance response
# (KeyRequestApproval, dashboard/portal_api_methods.go) only ever
# returns RawKey/Password — never a hash — so this is the real, complete
# set of fields available, not an abbreviated one.
#
# api_id is which seeded API (see record_api, above) this key was issued
# against — join it back against .apis[] for that API's own auth_type/
# listen_path/url. This is scripts/load-test/'s whole reason for
# existing: without it, a key on its own doesn't say what it can even be
# used to call.
record_key() {
  local dev_id="$1" raw_key="$2" api_id="$3" password="${4:-}"
  jq_update '(.developers[] | select(.id == $dev) | .keys) += [
      {"raw_key":$raw,"api_id":$api} + (if $pw != "" then {"password":$pw} else {} end)
    ]' --arg dev "$dev_id" --arg raw "$raw_key" --arg api "$api_id" --arg pw "$password"
}
record_pending_request() { # dev_id request_id api_id
  jq_update '(.developers[] | select(.id == $dev) | .pending_requests) += [{"id":$rid,"api_id":$api}]' \
    --arg dev "$1" --arg rid "$2" --arg api "$3"
}
finalize_state_file() {
  local out
  case "$STATE_FORMAT" in
    yaml) out=".seed-state/run-${RUN_SUFFIX}.yaml"; yq -p json -o yaml "$STATE_TMP" > "$out" ;;
    json) out=".seed-state/run-${RUN_SUFFIX}.json"; jq '.' "$STATE_TMP" > "$out" ;;
  esac
  rm -f "$STATE_TMP"
  info "wrote $out"
}

# ---- Admin / console users --------------------------------------------------
#
# #1 is always bootstrap.sh's own org-owner admin — never recreated here,
# just recorded, since it already exists and its credentials are exactly
# what .runtime.env (already sourced above) holds. --admin-users counts
# it, so --admin-users 3 (the default) creates 2 *more*. Each additional
# one gets its own random password and a run-suffixed email so seed.sh
# stays safe to run again (a fixed, unsuffixed email would collide with
# an earlier run's admin2/admin3 the second time this is called).

admin_count=0
if [[ $DRY_RUN -eq 1 ]]; then
  info "would record existing admin: $ADMIN_EMAIL"
  admin_count=1
else
  record_admin_user "bootstrap" "$ADMIN_EMAIL" "$ADMIN_PASSWORD"
  admin_count=1
fi

for ((n = 2; n <= ADMIN_USERS; n++)); do
  admin_email="admin-${RUN_SUFFIX}-${n}@example-poc.dev"
  admin_first="POC" admin_last="Admin${n}"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "would create admin user: $admin_first $admin_last <$admin_email>"
    admin_count=$((admin_count + 1))
    continue
  fi
  STEP=$((STEP + 1))
  progress_bar "$STEP" "$TOTAL_STEPS" "Creating admin user: $admin_email"
  admin_password="$(gen_password)"
  admin_id=$(create_admin_user "$admin_email" "$admin_first" "$admin_last" "$admin_password") \
    || { warn "skipping admin user $admin_email — creation failed"; continue; }
  record_admin_user "$admin_id" "$admin_email" "$admin_password"
  admin_count=$((admin_count + 1))
done

# ---- APIs + Policies + Catalogue -------------------------------------------

declare -a ALL_POLICY_IDS=()
declare -A POLICY_IDS_BY_TYPE=()
declare -A API_ID_BY_POLICY=()
policy_seq=0

api_short_desc() {
  case "$1" in
    keyless)   echo "Open, no credential required." ;;
    authToken) echo "Standard bearer-token access — the classic default." ;;
    basic)     echo "HTTP Basic Auth credentials." ;;
    hmac)      echo "Signed-request (HMAC) access." ;;
    jwt)       echo "JWT bearer access, shared-secret signed." ;;
    oauth)     echo "Tyk-native OAuth 2.0 access." ;;
    openid)    echo "OpenID Connect access via this stack's Keycloak." ;;
    mutualTLS) echo "Static mutual TLS access." ;;
    other)     echo "No auth mechanism configured — a deliberately ambiguous classic API." ;;
    *)         echo "Seeded API." ;;
  esac
}

for auth_type in "${TYPES[@]}"; do
  POLICY_IDS_BY_TYPE[$auth_type]=""
  for i in $(seq 1 "$APIS_PER_TYPE"); do
    name="${SEED_PREFIX} ${auth_type} API ${RUN_SUFFIX}-${i}"
    listen_path="/poc/${auth_type}/${RUN_SUFFIX}-${i}/"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "would create API+Policy+Catalogue entry: $name"
      continue
    fi
    STEP=$((STEP + 1))
    progress_bar "$STEP" "$TOTAL_STEPS" "Creating $auth_type API/Policy/Catalogue entry: $name"
    api_id=$(create_api "$name" "$listen_path" "$auth_type") || { warn "skipping $name — API creation failed"; continue; }
    policy_id=$(create_policy "$name" "$api_id" "$auth_type" "$policy_seq") || { warn "skipping $name — policy creation failed"; continue; }
    policy_seq=$((policy_seq + 1))
    catalogue_add "$api_id" "$policy_id" "$name" "$(api_short_desc "$auth_type")" "$auth_type"
    record_api "$api_id" "$name" "$auth_type" "$listen_path"
    record_policy "$policy_id" "$name"
    POLICY_IDS_BY_TYPE[$auth_type]+="${policy_id} "
    API_ID_BY_POLICY[$policy_id]="$api_id"
    # Keyless APIs have no credential at all on the classic side — the
    # Dashboard itself rejects both a key request and an admin-issued key
    # against one ("key requests for key-less APIs are not allowed",
    # confirmed live) — so a keyless policy is deliberately excluded from
    # the pool used to assign developer keys/pending requests below, even
    # though its API/Policy/Catalogue entry is still seeded and inventoried.
    if [[ "$auth_type" != "keyless" ]]; then
      ALL_POLICY_IDS+=("$policy_id")
    fi
  done
done

if [[ $DRY_RUN -eq 0 && ${#ALL_POLICY_IDS[@]} -eq 0 ]]; then
  die "no policies were created — nothing to issue developer keys against"
fi

# ---- Developers + Keys + Pending Requests ----------------------------------

pending_left="$PENDING_REQUESTS"
dev_count=0 key_count=0 pending_count=0

for n in $(seq 1 "$DEVELOPERS"); do
  IFS=$'\t' read -r first last email <<<"$(seeded_person "-${RUN_SUFFIX}-${n}")"
  if [[ $DRY_RUN -eq 1 ]]; then
    info "would create developer: $first $last <$email>"
    continue
  fi
  STEP=$((STEP + 1))
  progress_bar "$STEP" "$TOTAL_STEPS" "Creating developer $n/$DEVELOPERS: $email"
  dev_password="$(gen_password)"
  dev_id=$(create_developer "$email" "$first" "$last" "$dev_password") || { warn "skipping developer $email — creation failed"; continue; }
  record_developer "$dev_id" "$email" "$dev_password"
  dev_count=$((dev_count + 1))

  if (( pending_left > 0 )); then
    policy_id=$(rand_pick ALL_POLICY_IDS)
    api_id="${API_ID_BY_POLICY[$policy_id]:-}"
    if [[ -n "$api_id" ]]; then
      req_id=$(create_pending_request "$dev_id" "$policy_id" "$api_id")
      if [[ -n "$req_id" ]]; then
        record_pending_request "$dev_id" "$req_id" "$api_id"
        pending_count=$((pending_count + 1))
        pending_left=$((pending_left - 1))
        continue # a developer with a pending request doesn't also get issued keys this run, so `edp-migrate inventory`'s pending-request count matches --pending-requests exactly
      fi
    fi
  fi

  for _ in $(seq 1 "$KEYS_PER_DEV"); do
    policy_id=$(rand_pick ALL_POLICY_IDS)
    api_id="${API_ID_BY_POLICY[$policy_id]:-}"
    key_resp=$(issue_key_for_developer "$dev_id" "$policy_id")
    raw_key=$(json_get "$key_resp" '.RawKey // empty')
    key_password=$(json_get "$key_resp" '.Password // empty')
    [[ -n "$raw_key" ]] && record_key "$dev_id" "$raw_key" "$api_id" "$key_password"
    key_count=$((key_count + 1))
  done
done

if [[ $DRY_RUN -eq 0 ]]; then
  progress_bar_done
  finalize_state_file
fi

cat >&2 <<EOF

---------------------------------------------------------
Seeding complete (run suffix: ${RUN_SUFFIX}).

  APIs/Policies/Catalogue entries: $(( ${#TYPES[@]} * APIS_PER_TYPE )) requested across ${#TYPES[@]} auth type(s)
  Developers created:               $dev_count
  Keys issued:                      $key_count
  Pending key requests left open:   $pending_count
  Admin users (total, incl. #1):    $admin_count

  Dashboard:  ${DASHBOARD_URL}  (login: ${ADMIN_EMAIL} / ${ADMIN_PASSWORD})
  State log:  run-${RUN_SUFFIX}.${STATE_FORMAT} — every developer/admin's real
              password, and every issued key's raw credential, is in there.
$(if [[ "${SEED_STATE_VOLUME:-0}" == "1" ]]; then
  cat <<EOF2
              This container's own .seed-state/ lives in a named volume, not
              on your host disk — read it from your own shell instead:
                ./scripts/seed-state.sh show run-${RUN_SUFFIX}.${STATE_FORMAT}
EOF2
else
  echo "              Find it directly at: poc-environment/.seed-state/run-${RUN_SUFFIX}.${STATE_FORMAT}"
fi)

Run it again with a different --scale/--apis-per-type/--auth-types to add more, or
scripts/reset.sh to remove everything this toolkit created.
---------------------------------------------------------
EOF
