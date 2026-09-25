#!/usr/bin/env bash
# seed-state.sh — view .seed-state/run-*.yaml|json files (every
# developer/admin's real password and every issued key's raw credential)
# from the host, for stacks brought up with `./up.sh --seed-state-volume`
# — that flag puts .seed-state/ in a named Docker volume instead of this
# repo's own default host bind mount (poc-environment/.seed-state/), for
# environments where a bind mount doesn't work (see
# docker-compose.namedvolume.yml's own comment for the full story). If
# you did NOT pass --seed-state-volume, you don't need this script at
# all — just open poc-environment/.seed-state/ directly.
#
# Usage:
#   ./scripts/seed-state.sh list          # every run-*.yaml|json file, newest first
#   ./scripts/seed-state.sh show          # the most recent run's full contents
#   ./scripts/seed-state.sh show run-123.yaml   # one specific run
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Always merges in docker-compose.namedvolume.yml — this script only
# makes sense against the named-volume configuration (the default host
# bind mount needs no help to read). Reuses the "seed" service's own
# image + volume mount instead of guessing compose's own generated
# volume name and reaching for a raw `docker run -v <name>:...` — same
# volume, no duplicated knowledge of how compose names it, and no
# separate image to build/maintain.
_run() { docker compose -f docker-compose.yml -f docker-compose.namedvolume.yml --profile seed run --rm --entrypoint sh seed -c "$1"; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [list|show [FILE]]
  list         every run-*.yaml|json file in the seed-state volume, newest first (default)
  show [FILE]  print one file's contents — the most recent run if FILE is omitted
EOF
}

case "${1:-list}" in
  list)
    _run 'ls -1t .seed-state/run-*.y*ml .seed-state/run-*.json 2>/dev/null | xargs -n1 basename' || {
      echo "[x] no run-*.yaml|json files found — seed something first (./up.sh, or docker compose --profile seed run --rm seed ...)" >&2
      exit 1
    }
    ;;
  show)
    file="${2:-}"
    if [[ -z "$file" ]]; then
      _run 'f=$(ls -1t .seed-state/run-*.y*ml .seed-state/run-*.json 2>/dev/null | head -1); if [ -n "$f" ]; then cat "$f"; else echo "no run-*.yaml|json files found" >&2; exit 1; fi'
    else
      _run "cat .seed-state/${file}"
    fi
    ;;
  -h|--help) usage ;;
  *) echo "[x] unknown command: $1" >&2; usage; exit 1 ;;
esac
