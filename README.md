# EDP Migration POC

A self-contained proof-of-concept environment for **edp-migrate**, the tool
that migrates a Tyk Classic Developer Portal (the developer portal built
into the Tyk Dashboard) to the **Enterprise Developer Portal (EDP)**.

This directory brings up the entire stack you need to see a real migration
happen — Tyk Gateway, Tyk Dashboard, the Enterprise Developer Portal,
Keycloak, and the migration tool itself, all via `docker compose` — and
includes scripts that populate the Classic Portal with a realistic,
variably-sized set of developers, APIs, and keys so there's something real
to migrate.

If you're new here, the short version is:

```
./up.sh --scale small
```

Then open <http://localhost:9090> and follow
[docs/MIGRATION_WALKTHROUGH.md](docs/MIGRATION_WALKTHROUGH.md).

## What's in this stack

| Service | What it is | URL |
|---|---|---|
| Tyk Gateway | The API gateway/proxy | <http://localhost:18080> |
| Tyk Dashboard | Management API + the **Classic Portal** you'll migrate from | <http://localhost:13000> |
| Tyk Pump | Ships analytics from the Gateway into Postgres | (no UI) |
| Enterprise Developer Portal (EDP) | The **migration target** | <http://localhost:13001> |
| Keycloak | An external IdP, for exercising OpenID Connect/DCR scenarios | <http://localhost:18180> |
| Postgres | Storage for the Dashboard, EDP, and Keycloak (separate databases) | localhost:15432 |
| Redis | The Gateway's key store | localhost:16379 |
| **edp-migrate** | The migration tool itself | <http://localhost:9090> |

Every host port above is the exact default `edp-migrate`'s own Setup wizard
prefills (`DefaultLocalConfig`, in the core tool's own repo) — as
long as you leave `.env`'s `*_HOST_PORT` variables alone, the tool needs
zero manual configuration to find this stack.

## Where `edp-migrate` itself comes from

This stack pulls a **published image** (`EDP_MIGRATE_IMAGE` in
`.env.example`, default `docker.io/ataimo007/edp-migrate:latest`) — it
never builds from source, so this directory works as a fully standalone
repo with no sibling source tree required. Every tagged release publishes
to all of the following simultaneously:

| Channel | What you get |
|---|---|
| [Docker Hub](https://hub.docker.com/r/ataimo007/edp-migrate) | `docker.io/ataimo007/edp-migrate:X.Y.Z` / `:latest` — what this stack uses by default |
| [ghcr.io](https://github.com/Ataimo007/edp-migration/pkgs/container/edp-migrate) | `ghcr.io/ataimo007/edp-migrate:X.Y.Z` / `:latest` — set `EDP_MIGRATE_IMAGE=ghcr.io/ataimo007/edp-migrate:latest` in `.env` to use this instead |
| GitHub Releases | Plain cross-compiled binaries (`.tar.gz`, linux/darwin, amd64/arm64) + checksums, if you'd rather run `edp-migrate` directly on your machine than in a container |
| Buildkite Package Registries | `.deb`/`.rpm` packages, for installing `edp-migrate` as a native system package on a real (non-container) Linux host |

Pin a specific version rather than always tracking `:latest` by setting
`EDP_MIGRATE_IMAGE=docker.io/ataimo007/edp-migrate:X.Y.Z` in `.env`.

## Prerequisites

1. [Docker](https://docs.docker.com/get-docker/) with Compose v2 (`docker compose version`).
2. A Tyk trial license — sign up at <https://tyk.io/sign-up/> ("guided
   evaluation") and put it in `.env` as `DASH_LICENSE` (`up.sh` will ask
   for it and write `.env` for you the first time you run it).
3. `curl` and `jq` on your machine (the seed scripts use them directly —
   they don't run inside a container).

## Quickstart

```sh
cp .env.example .env        # then edit .env and set DASH_LICENSE
./up.sh --scale small       # brings the stack up, bootstraps, and seeds it
```

`up.sh` is just `docker compose up -d` (pulling the published
`edp-migrate` image — see `EDP_MIGRATE_IMAGE` in `.env.example` to use
ghcr.io or a pinned version instead of Docker Hub `:latest`) followed by
`scripts/bootstrap.sh` and `scripts/seed.sh` — see
[docs/SEEDING_GUIDE.md](docs/SEEDING_GUIDE.md) if you'd rather run those
steps yourself (e.g. to reseed at a different scale without restarting the
stack).

## What to do next

- **New to the tool?** Read [docs/MIGRATION_WALKTHROUGH.md](docs/MIGRATION_WALKTHROUGH.md) —
  a step-by-step tour of Setup → Discovery → Backup → Migration → Cutover →
  Decommission using the data you just seeded.
- **Want a bigger or differently-shaped dataset?** Read
  [docs/SEEDING_GUIDE.md](docs/SEEDING_GUIDE.md) for `seed.sh`'s full option
  list (scale, developer count, which classic auth types to generate, how
  many pending key requests to leave open, and so on).
- **Curious how the pieces fit together?** Read
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Something not working as expected?** See
  [docs/MIGRATION_WALKTHROUGH.md](docs/MIGRATION_WALKTHROUGH.md)'s
  "Debugging" section — `edp-migrate` logs every API call, database
  query, and web request at a configurable level
  (`EDP_MIGRATE_LOG_LEVEL`), always to `docker compose logs edp-migrate`.

## Resetting

- `scripts/reset.sh` — deletes everything `seed.sh` created on the
  **Classic Portal** side (developers/APIs/policies/catalogue/pending
  requests), leaving the org and stack running so you can reseed
  immediately.
- `scripts/reset.sh --full` — `docker compose down -v`: wipes every
  container **and volume**, irreversibly. **Use this, not the plain
  form above, any time you've also run `edp-migrate plan`/`execute`
  against this data** — EDP has a confirmed bug where deleting a
  migrated Product/Plan whose underlying classic Policy is already gone
  fails and leaves the row permanently orphaned in EDP's own database,
  and there is no reliable way to clean that up incrementally. Between
  full seed → migrate → demo cycles, always tear the whole stack down.

## Troubleshooting

- **"mounts denied ... not shared from the host"** (Docker Desktop only):
  add this repo's path under Docker Desktop's Preferences → Resources →
  File Sharing, then retry. This affects the `postgres-init/` bind mount
  that creates the `tyk_portal`/`keycloak` databases on first boot.
- **Dashboard/Portal container won't start / license error**: double-check
  `DASH_LICENSE` in `.env` — both the Dashboard and the EDP container
  reuse the same trial license.
- Everything else: `docker compose logs -f <service>`.

## Using MongoDB instead of Postgres

```sh
docker compose -f docker-compose.yml -f docker-compose.mongo.yml up -d
```

`edp-migrate`'s Setup wizard has an explicit Mongo/Postgres choice for the
Classic Dashboard's database step — there's no way for the tool to detect
this automatically, so tell it Mongo if you use this override.
