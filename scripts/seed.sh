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

RUNTIME_FILE="$(pwd)/.runtime.env"
[[ -f "$RUNTIME_FILE" ]] || die "no $RUNTIME_FILE found — run scripts/bootstrap.sh first"
# shellcheck source=/dev/null
source "$RUNTIME_FILE"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--scale small|medium|large] [options]

Scale presets (developers / APIs per auth type / keys per developer / pending requests):
  small   (default)  5  / 1 / 1 / 2
  medium              25 / 2 / 2 / 5
  large               100 / 3 / 3 / 15

Options (override individual scale-preset values):
  --scale NAME              small | medium | large           (default: small)
  --developers N             number of developer accounts to create
  --apis-per-type N          how many API+Policy+Catalogue trios per auth type
  --keys-per-developer N     keys issued per developer (beyond any pending request)
  --pending-requests N       how many developers get an unapproved pending key request instead
  --auth-types LIST          comma-separated subset of:
                              keyless,authToken,basic,hmac,jwt,oauth,openid,mutualTLS,other
                              (default: all of them)
  --run-suffix STR           uniqueness suffix for names/emails this run (default: random)
  --dry-run                  print what would be created; make no API calls
  -v, --verbose               print every API call and response
  -h, --help                  this help
EOF
}

SCALE="small"
DEVELOPERS="" APIS_PER_TYPE="" KEYS_PER_DEV="" PENDING_REQUESTS=""
AUTH_TYPES="keyless,authToken,basic,hmac,jwt,oauth,openid,mutualTLS,other"
RUN_SUFFIX="$((RANDOM % 100000))"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scale) SCALE="$2"; shift 2 ;;
    --developers) DEVELOPERS="$2"; shift 2 ;;
    --apis-per-type) APIS_PER_TYPE="$2"; shift 2 ;;
    --keys-per-developer) KEYS_PER_DEV="$2"; shift 2 ;;
    --pending-requests) PENDING_REQUESTS="$2"; shift 2 ;;
    --auth-types) AUTH_TYPES="$2"; shift 2 ;;
    --run-suffix) RUN_SUFFIX="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; usage; exit 1 ;;
  esac
done

case "$SCALE" in
  small)  d_def=5;   a_def=1; k_def=1; p_def=2 ;;
  medium) d_def=25;  a_def=2; k_def=2; p_def=5 ;;
  large)  d_def=100; a_def=3; k_def=3; p_def=15 ;;
  *) die "unknown --scale '$SCALE' (want small|medium|large)" ;;
esac
DEVELOPERS="${DEVELOPERS:-$d_def}"
APIS_PER_TYPE="${APIS_PER_TYPE:-$a_def}"
KEYS_PER_DEV="${KEYS_PER_DEV:-$k_def}"
PENDING_REQUESTS="${PENDING_REQUESTS:-$p_def}"

IFS=',' read -ra TYPES <<<"$AUTH_TYPES"

info "scale=$SCALE developers=$DEVELOPERS apis-per-type=$APIS_PER_TYPE keys-per-developer=$KEYS_PER_DEV pending-requests=$PENDING_REQUESTS auth-types=${TYPES[*]}"
[[ $DRY_RUN -eq 1 ]] && warn "--dry-run: no API calls will be made"

mkdir -p .seed-state
STATE_FILE=".seed-state/run-${RUN_SUFFIX}.jsonl"
record() { # record TYPE ID NAME
  printf '{"type":"%s","id":"%s","name":%s}\n' "$1" "$2" "$(jq -Rn --arg n "$3" '$n')" >> "$STATE_FILE"
}

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
    name="${SEED_PREFIX} ${auth_type} API #${i}-${RUN_SUFFIX}"
    listen_path="/poc/${auth_type}/${i}-${RUN_SUFFIX}/"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "would create API+Policy+Catalogue entry: $name"
      continue
    fi
    api_id=$(create_api "$name" "$listen_path" "$auth_type") || { warn "skipping $name — API creation failed"; continue; }
    policy_id=$(create_policy "$name" "$api_id" "$auth_type" "$policy_seq") || { warn "skipping $name — policy creation failed"; continue; }
    policy_seq=$((policy_seq + 1))
    catalogue_add "$api_id" "$policy_id" "$name" "$(api_short_desc "$auth_type")" "$auth_type"
    record api "$api_id" "$name"
    record policy "$policy_id" "$name"
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
    ok "seeded $auth_type API/Policy/Catalogue entry: $name"
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
  dev_id=$(create_developer "$email" "$first" "$last" "PocDev123!") || { warn "skipping developer $email — creation failed"; continue; }
  record developer "$dev_id" "$email"
  dev_count=$((dev_count + 1))

  if (( pending_left > 0 )); then
    policy_id=$(rand_pick ALL_POLICY_IDS)
    api_id="${API_ID_BY_POLICY[$policy_id]:-}"
    if [[ -n "$api_id" ]]; then
      req_id=$(create_pending_request "$dev_id" "$policy_id" "$api_id")
      if [[ -n "$req_id" ]]; then
        record request "$req_id" "$email"
        pending_count=$((pending_count + 1))
        pending_left=$((pending_left - 1))
        continue # a developer with a pending request doesn't also get issued keys this run, so `edp-migrate inventory`'s pending-request count matches --pending-requests exactly
      fi
    fi
  fi

  for _ in $(seq 1 "$KEYS_PER_DEV"); do
    policy_id=$(rand_pick ALL_POLICY_IDS)
    issue_key_for_developer "$dev_id" "$policy_id" >/dev/null
    key_count=$((key_count + 1))
  done
done

cat >&2 <<EOF

---------------------------------------------------------
Seeding complete (run suffix: ${RUN_SUFFIX}).

  APIs/Policies/Catalogue entries: $(( ${#TYPES[@]} * APIS_PER_TYPE )) requested across ${#TYPES[@]} auth type(s)
  Developers created:               $dev_count
  Keys issued:                      $key_count
  Pending key requests left open:   $pending_count

  Dashboard:  ${DASHBOARD_URL}  (login: ${ADMIN_EMAIL} / ${ADMIN_PASSWORD})
  State log:  ${STATE_FILE}

Run it again with a different --scale/--auth-types to add more, or
scripts/reset.sh to remove everything this toolkit created.
---------------------------------------------------------
EOF
