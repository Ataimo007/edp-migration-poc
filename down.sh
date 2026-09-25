#!/usr/bin/env bash
# down.sh — the one-command teardown to go with up.sh: stops and removes
# every container, network, AND volume this stack created (Postgres/Redis/
# Portal data, EDP's database, the edp-migrate /data volume), plus the
# local .seed-state/ and .runtime.env files up.sh/seed.sh/bootstrap.sh
# leave behind — so the next `./up.sh` starts from a genuinely clean slate,
# not just stopped containers sitting on top of old data.
#
# This is deliberately just scripts/reset.sh --full under a name that
# mirrors up.sh (people reach for `./down.sh` without needing to know
# reset.sh exists, or that plain reset.sh only cleans the Classic Portal
# side) — see reset.sh's own header for exactly why --full (not
# reset.sh's default mode) is the only reliable teardown once EDP has ever
# had `edp-migrate execute` run against this stack.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: $(basename "$0")

Tears down the whole stack: every container, network, and volume this
stack created (Postgres/Redis/Portal data, EDP's database, the
edp-migrate /data volume), plus the local .seed-state/ and .runtime.env
files up.sh/seed.sh/bootstrap.sh leave behind — so the next ./up.sh
starts from a genuinely clean slate. Equivalent to scripts/reset.sh
--full (see that script's own --help for why --full, not its default
mode, is the only reliable teardown here). Prompts for confirmation
before deleting anything. Takes no options of its own.
EOF
  exit 0
fi

exec scripts/reset.sh --full
