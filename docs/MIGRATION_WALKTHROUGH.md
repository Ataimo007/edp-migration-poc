# Migration Walkthrough

A step-by-step tour of `edp-migrate` using the stack and seed data from
this POC. Do the Quickstart in the main [README](../README.md) first —
you should have a running stack with a seeded Classic Portal before
starting here.

`edp-migrate` is both a web UI (`http://localhost:9090`, no arguments) and
a set of CLI subcommands, run inside the `edp-migrate` container (or, if
you have Go installed, directly against the same stack). This walkthrough
uses the web UI for Phase 0 (it's genuinely the easiest way to do it once)
and shows the equivalent CLI command at each later phase, since the web UI
just re-invokes the same binary as a subprocess.

## Phase 0 — Setup

Open <http://localhost:9090> in your browser — that part's always the
*host*-mapped port, since your browser runs outside the compose network.
The five-page wizard's own default prefill (`edp-migrate`'s
`DefaultLocalConfig`) assumes `edp-migrate` itself is also running on your
host (e.g. via `go run ./cmd/edp-migrate`), so those defaults use
`localhost:<host-port>` for every downstream connection. That's **wrong**
for this stack's normal setup, where `edp-migrate` runs as its own
container on the compose network — `localhost` from inside that container
means the container itself, not your host. Override every field to the
internal service hostnames below instead:

| Page | Value |
|---|---|
| Dashboard (Classic Portal) | URL `http://tyk-dashboard:3000`; credential = the `DASH_TOKEN` printed by `scripts/bootstrap.sh` (also in `.runtime.env`) |
| Classic Dashboard database | Postgres, `user=postgres password=topsecretpassword host=tyk-postgres port=5432 database=tyk_analytics sslmode=disable` |
| Enterprise Developer Portal | URL `http://tyk-ent-portal:3001/portal-api`; credential = an EDP admin JWT (Setup mints one live once you submit this page — enter EDP's admin login the first time) |
| EDP database | `user=postgres password=topsecretpassword host=tyk-postgres port=5432 database=tyk_portal sslmode=disable` |
| Redis (Gateway key store) | `tyk-redis:6379` |

Running `edp-migrate` directly on your host instead (Go installed, no
container)? Use `localhost:<host-port>` for each of the above — the
defaults the wizard already prefills — since your host reaches every other
service through its mapped port, not the internal compose network.

Each page has its own "Test Connectivity" check — don't move on until it's
green. If you used `docker-compose.mongo.yml`, tell the wizard Mongo, not
Postgres, on the Classic Dashboard database page.

## Phase 1 — Discovery (`inventory`)

```sh
docker compose exec edp-migrate edp-migrate inventory
```

Walks the entire Classic Portal read-only and prints a discovery report —
developer/policy/catalogue/key counts, which classic auth types are
present, whether DCR is enabled. Compare it against what you asked
`seed.sh` for; they should match exactly (see
[SEEDING_GUIDE.md](SEEDING_GUIDE.md) if anything looks off, e.g. keyless
APIs never appear in a key/pending-request count on purpose).

## Phase 2 — Backup

```sh
docker compose exec edp-migrate edp-migrate backup
```

A full snapshot: fresh inventory, every Dashboard DB table relevant to the
portal, developer/admin-user password hashes, and the entire Redis
keyspace. This is your safety net before anything below writes to EDP —
`edp-migrate restore-redis` can replay the Redis portion verbatim if
something goes wrong later (Postgres/Mongo table dumps are reference
snapshots, not a restorable `pg_dump`/`mongodump` equivalent — see the
tool's own `internal/backup` docs for why).

## Phase 3 — Migration (`plan` / `execute`)

```sh
docker compose exec edp-migrate edp-migrate plan     # dry run — writes a plan, changes nothing
docker compose exec edp-migrate edp-migrate execute   # applies it (asks you to confirm)
```

`plan` shows you exactly what `execute` would do: developers become EDP
users, catalogue entries become Products/Plans (auth-type-appropriate —
see [SEEDING_GUIDE.md](SEEDING_GUIDE.md)'s auth-type table for which ones
land as a real subscribable Product vs. a documentation-only one), issued
keys get adopted as EDP credentials, pending key requests become EDP
Access Requests. `execute` is safely re-runnable — anything already
recorded in the tool's ledger (`.edp-migrate`/ledger, inside the
container's `/data` volume) is skipped on a second run, so you can fix a
partial failure and run it again rather than starting over.

## Phase 4 — Report

```sh
docker compose exec edp-migrate edp-migrate report
```

A read-only reconciliation pass: migrated vs. still-pending counts per
resource type, plus anything flagged for manual review (mTLS APIs, the
flagless `other` bucket, DCR entries waiting on operator input).

## Phase 5 — Cutover / Decommission

```sh
docker compose exec edp-migrate edp-migrate cutover            # deactivates migrated classic Policies
docker compose exec edp-migrate edp-migrate cutover-rollback    # reverses cutover alone, if needed
docker compose exec edp-migrate edp-migrate decommission        # PERMANENTLY deletes migrated developers/Policies
```

Cutover deactivates every migrated classic Policy org-wide — every key
still on one switches over to its migrated EDP Plan tier immediately, no
per-key action needed. It's reversible via `cutover-rollback` right up
until you run `decommission`, which is genuinely destructive (it takes its
own fresh backup first, and asks you to type "yes").

**DCR-migrated Products, and every documentation-only Product** (the
`hmac`/`oauth`/`openid`/`keyless`/`other` buckets from your seed data) are
automatically **skipped** by both Cutover and Decommission — there's no
staged classic-side object to deactivate/delete for either. `edp-migrate`
reports this explicitly rather than silently leaving them alone
unexplained.

**The 30-day Decommission gate is a web UI thing, not a CLI thing.** The
web wizard blocks Decommission for 30 days after Cutover first runs (a
deliberate safety window). The CLI command shown above does **not**
enforce that gate — `decommission` will run immediately after `cutover`
if you invoke it this way. That's the right behavior for exercising this
POC's own test cycle quickly, but worth knowing if you're demonstrating
the tool's real production safety behavior specifically — do that through
the web UI (`http://localhost:9090`) instead.

## Debugging something that isn't working

Every category of operation — API calls to the Classic Dashboard/EDP,
direct database queries, web UI requests, migration activity — is logged
at an appropriate level, always to the container's stderr (`docker
compose logs edp-migrate`), separate from the tool's own stdout output:

```sh
docker compose exec -e EDP_MIGRATE_LOG_LEVEL=debug edp-migrate edp-migrate inventory
```

`EDP_MIGRATE_LOG_LEVEL` accepts `debug`/`verbose` (every API call and DB
query), `info` (default), `warn`, or `error`. `EDP_MIGRATE_LOG_FORMAT=json`
gives structured output if you're piping `docker compose logs` into
something that parses it.

## Starting over

Run `scripts/reset.sh --full` (full `docker compose down -v`) before
reseeding and re-migrating — see the README's "Resetting" section for
why the plain `scripts/reset.sh` isn't enough once you've run
`plan`/`execute`.
