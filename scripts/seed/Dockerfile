# syntax=docker/dockerfile:1
# Built and run via docker-compose.yml's own "seed" service (never part of
# the always-up stack — see that service's own "profiles:" — invoked
# explicitly by ./up.sh, or by hand: `docker compose run --rm seed ...`).
#
# Runs scripts/seed.sh's own logic in its own container instead of this
# devcontainer's own host shell, specifically so its output (the
# .seed-state/ directory) lands in the "seed-state" named volume the
# "locust" service also mounts — two independent containers sharing one
# named volume has nothing to do with (and isn't blocked by) this
# devcontainer's own Docker Desktop file-sharing config, unlike a host
# bind mount (see scripts/load-test/Dockerfile's own comment for the
# fuller story on why that path was a dead end).
#
# Build context is poc-environment/ itself (docker-compose.yml's own
# `context: .` for this service), not this directory — so scripts/seed.sh
# and its lib/*.sh dependencies can be copied in below without needing a
# separate copy of them living next to this Dockerfile.
FROM alpine:3.20

# bash: seed.sh/lib/*.sh use bash-only syntax (associative arrays, [[ ]],
# etc.), not sh-portable. jq/yq: the same state-file tooling seed.sh
# already assumed was available on the host. curl: every Dashboard API
# call. openssl: lib/common.sh's own gen_password() (confirmed live this
# was missing from Alpine's base image — every generated password came
# out empty, which then broke every downstream call that submitted one).
RUN apk add --no-cache bash curl jq yq openssl

WORKDIR /poc-environment
COPY scripts/ scripts/
RUN chmod +x scripts/*.sh scripts/lib/*.sh

ENTRYPOINT ["scripts/seed.sh"]
