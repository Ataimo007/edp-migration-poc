#!/usr/bin/env bash
# run.sh — the "locust" compose service already autostarts a run on its
# own (entrypoint.sh's own --autostart, one worker per available
# developer key) the moment it comes up — you don't need this script just
# to get traffic flowing. Use this instead when you want a *bounded*,
# fixed-duration run with a final stats summary printed at the end (a
# scripted/CI-style pass, or just "run for exactly 5 minutes and tell me
# the result") rather than the indefinite run entrypoint.sh already
# started. Drives that same running instance via Locust's own REST API
# (POST /swarm, GET /stats/requests, GET /stop) instead of running a
# second `locust` process inside the container.
#
# That second-process approach (`docker compose exec locust locust -f
# ... --headless ...`) was tried first and confirmed live, repeatedly, to
# return control to the shell almost immediately regardless of --t,
# despite `docker top` showing the spawned process still genuinely
# running server-side — an exec/signal-forwarding quirk in this
# environment's own (nested) Docker setup that wasn't worth chasing
# further, especially once it became clear there's a strictly better
# option anyway: the persistent instance already exposes everything a
# script needs over its own REST API, so there's no reason to spawn a
# competing second process in the first place.
#
# Usage:
#   ./run.sh                    # one worker per available developer key, spawned all
#                                 at once, running for 2 minutes — see -u/-r below
#   ./run.sh -u 100 -r 10 -t 5m # override any of the three
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # poc-environment/ — where .env lives
command -v jq >/dev/null 2>&1 || { echo "[x] jq is required (used to read /credential-count's response)" >&2; exit 1; }

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi
BASE_URL="http://localhost:${LOCUST_HOST_PORT:-8089}"

USERS=""
RATE=""
DURATION_RAW="2m"

usage() {
  cat <<EOF
Usage: $(basename "$0") [-u USERS] [-r SPAWN_RATE] [-t DURATION]

  -u USERS         number of simulated users to swarm to (default: one per
                    available developer key — GET /credential-count, so
                    every seeded API actually gets called, not a subset)
  -r SPAWN_RATE    users started per second while ramping up (default:
                    USERS itself — every worker starts at once)
  -t DURATION      how long to run before stopping, e.g. 30s, 2m, 1h (default: 2m)
  -h, --help       this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u) USERS="$2"; shift 2 ;;
    -r) RATE="$2"; shift 2 ;;
    -t) DURATION_RAW="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[x] unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$USERS" ]]; then
  USERS=$(curl -sf "$BASE_URL/credential-count" | jq -r '.count // empty')
  [[ -n "$USERS" && "$USERS" -gt 0 ]] 2>/dev/null || {
    echo "[x] couldn't determine a credential count from $BASE_URL/credential-count — is the locust container up and seeded? (docker compose ps locust) Pass -u explicitly to override." >&2
    exit 1
  }
  echo "[*] no -u given — defaulting to $USERS (one worker per available developer key)"
fi
RATE="${RATE:-$USERS}"

# Locust's own -t syntax (30s, 2m, 1h30m, ...) — parsed into plain seconds
# for this script's own `sleep`, not passed to Locust itself (the running
# instance is driven entirely over HTTP below, no --t flag involved).
duration_seconds() {
  local raw="$1" total=0 num unit
  while [[ -n "$raw" ]]; do
    [[ "$raw" =~ ^([0-9]+)([smh])(.*)$ ]] || { echo "[x] bad duration '$1' (want e.g. 30s, 2m, 1h30m)" >&2; exit 1; }
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; raw="${BASH_REMATCH[3]}"
    case "$unit" in
      s) total=$((total + num)) ;;
      m) total=$((total + num * 60)) ;;
      h) total=$((total + num * 3600)) ;;
    esac
  done
  echo "$total"
}
DURATION_SECONDS=$(duration_seconds "$DURATION_RAW")

echo "[*] starting a swarm at $BASE_URL: $USERS user(s), spawn rate $RATE, running for $DURATION_RAW"
resp=$(curl -sf -X POST "$BASE_URL/swarm" --data-urlencode "user_count=$USERS" --data-urlencode "spawn_rate=$RATE") || {
  echo "[x] couldn't reach $BASE_URL — is the locust container up? (docker compose ps locust)" >&2
  exit 1
}
echo "$resp" | grep -q '"success": *true' || { echo "[x] locust refused to start: $resp" >&2; exit 1; }

sleep "$DURATION_SECONDS"

echo "[*] stopping the swarm"
curl -sf "$BASE_URL/stop" >/dev/null

echo "[*] final stats:"
curl -sf "$BASE_URL/stats/requests"
echo
echo "[*] full detail (including per-endpoint breakdowns, response-time percentiles): $BASE_URL — the web UI itself, or GET $BASE_URL/stats/requests directly"
