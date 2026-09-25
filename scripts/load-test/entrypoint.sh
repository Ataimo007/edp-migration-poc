#!/bin/sh
# entrypoint.sh — the "locust" compose service starts alongside the rest
# of the stack (./up.sh's own `docker compose up -d`), *before* the
# "seed" service has run (./up.sh calls that next) — locustfile.py has
# nothing to load yet at that point, so this waits for at least one
# .seed-state/run-*.yaml|json file to actually exist before starting
# Locust for real, instead of crashing (or serving with zero credentials)
# in that race. That file arrives via the "seed-state" named volume both
# this service and "seed" mount (docker-compose.yml) — a live, shared
# volume, not a copy: whatever "seed" writes shows up here immediately,
# no restart needed just to *see* a new file (see below for why a
# restart is still needed to actually *load* it).
#
# Runs Locust's own persistent web UI (never a fixed-duration --headless
# run) — this is a long-lived part of the stack now, the same as
# tyk-dashboard/tyk-gateway, not a one-shot job that should exit once a
# timed run finishes.
#
# --autostart (without --headless or --autoquit) starts a swarm the
# moment the web UI comes up, using whatever num_users/spawn_rate are
# already set on environment.parsed_options at that point (locust/main.py's
# own start_automatic_run) — exactly the values locustfile.py's own
# events.init hook already sets, dynamically, to the number of usable
# credentials this seed run produced. So this needs no -u/-r of its own:
# confirmed live, an operator visiting http://localhost:${LOCUST_HOST_PORT:-8089}
# now sees a run already in progress, one worker per available developer
# key, with no form to fill in and no button to click first. Leaving
# --autoquit unset keeps the web UI (and its live stats) running
# indefinitely afterward — stop/restart a run from the UI, or via
# run.sh's own /stop, whenever you actually want to.
#
# locustfile.py loads its credentials once, at import time — if you
# re-seed (or scripts/reset.sh) after this container is already up,
# restart it (`docker compose restart locust`) to pick up the new
# .seed-state/ file; it won't notice a new one on its own.
set -eu

echo "[locust] waiting for the 'seed' service to write a .seed-state/run-*.yaml|json file..."
while true; do
  for f in /poc-environment/.seed-state/run-*.yaml /poc-environment/.seed-state/run-*.yml /poc-environment/.seed-state/run-*.json; do
    if [ -e "$f" ]; then
      echo "[locust] found $f — starting Locust's web UI"
      exec locust -f /poc-environment/scripts/load-test/locustfile.py --web-host 0.0.0.0 --autostart "$@"
    fi
  done
  sleep 2
done
