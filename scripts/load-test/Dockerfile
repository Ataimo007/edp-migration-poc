# syntax=docker/dockerfile:1
# Built and run via docker-compose.yml's own "locust" service (started
# alongside the rest of the stack by ./up.sh) — see this directory's
# README.md for the actual usage. Not meant to be built/run standalone.
FROM locustio/locust:2.31.6

# The base image runs as a non-root "locust" user by default — root here
# instead, purely so the setup steps below (and a `docker cp` of a fresh
# .seed-state file into this same running container — see
# docker-compose.yml's own comment on why that's how state gets in here
# at all) can freely write under WORKDIR. This is a local, throwaway POC
# tool with no real security boundary to preserve, so that trade is fine.
USER root

# PyYAML for locustfile.py's own .seed-state/run-*.yaml parsing — not in
# Locust's base image, and small enough that installing it once here (at
# build time) beats doing it at every container start.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# locustfile.py/entrypoint.sh are baked in at build time rather than bind-
# mounted — this devcontainer's own Docker Desktop file-sharing config
# doesn't include this path (confirmed live: "mounts denied ... not
# shared from the host"), the same class of issue docker-compose.yml's
# own postgres-init comment already flagged for a different bind mount.
# Edit either file and re-run `docker compose up -d --build locust` to
# pick up the change — no live-edit-without-rebuild the way a mount would
# give you.
WORKDIR /poc-environment
COPY locustfile.py entrypoint.sh scripts/load-test/
RUN chmod +x scripts/load-test/entrypoint.sh && mkdir -p .seed-state

ENTRYPOINT ["scripts/load-test/entrypoint.sh"]
