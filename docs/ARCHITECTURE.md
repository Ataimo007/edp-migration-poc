# Architecture

## The problem this POC demonstrates

Tyk's **Classic Developer Portal** lives inside the Tyk Dashboard itself —
developers, API catalogue entries, keys, and pending key requests are all
Dashboard-native objects, managed through the Dashboard's own `/api/portal/*`
REST API. The **Enterprise Developer Portal (EDP)** is a separate product
(its own container, its own database, its own API) with a different data
model — Products, Plans, Providers, Applications, Access Requests — built
for a richer, standalone developer-experience story.

`edp-migrate` (the tool this POC exists to exercise) walks everything on
the Classic side and recreates the equivalent on the EDP side: developers
become EDP users, catalogue entries become Products/Plans, issued keys get
adopted as credentials, and so on. `../MIGRATION_PLAN.md` at the repo root
is the full design document for exactly how each resource type maps.

## The stack

```
                      ┌─────────────┐
                      │  Keycloak   │  external IdP (OpenID Connect / DCR)
                      └──────┬──────┘
                             │
   ┌──────────┐       ┌──────────────┐       ┌─────────────┐
   │  Tyk     │──────▶│ Tyk Dashboard│◀──────│  Tyk Pump   │
   │  Gateway │       │ (Classic     │       └──────┬──────┘
   └────┬─────┘       │  Portal)     │              │
        │              └──────┬───────┘              │
        │                     │                       │
        ▼                     ▼                       ▼
   ┌─────────┐          ┌───────────┐           ┌───────────┐
   │  Redis  │          │  Postgres │◀──────────│  EDP      │
   │ (keys)  │          │ (3 DBs:   │           │ (its own  │
   └─────────┘          │ dashboard,│           │  DB, same │
                         │ portal,   │           │  Postgres │
                         │ keycloak) │           │  instance)│
                         └───────────┘           └───────────┘

                    ┌────────────────┐
                    │  edp-migrate   │  reads Dashboard + Postgres + Redis,
                    │  (this repo's  │  writes EDP — the tool under test
                    │  own tool)     │
                    └────────────────┘
```

All three logical databases (the Classic Dashboard's `tyk_analytics`, EDP's
`tyk_portal`, and Keycloak's own `keycloak`) live in **one** Postgres
instance, in separate databases — `postgres-init/01-create-databases.sql`
creates the latter two on first boot (`tyk_analytics` is created by the
`POSTGRES_DB` environment variable already).

## Why seed the Classic side at all?

A brand-new stack has an empty Classic Portal — nothing to migrate, so
nothing to actually watch `edp-migrate` do. `scripts/seed.sh` (see
[SEEDING_GUIDE.md](SEEDING_GUIDE.md)) populates the Classic Dashboard with
developers, APIs across every classic auth type the migration tool has
distinct handling for, keys, and pending key requests, at a scale you
control — so the walkthrough in
[MIGRATION_WALKTHROUGH.md](MIGRATION_WALKTHROUGH.md) has something real to
work with.

## Directory layout

```
poc-environment/
├── docker-compose.yml         the full stack, including edp-migrate itself
├── docker-compose.mongo.yml   optional override: Mongo instead of Postgres
├── confs/                     env files for each Tyk component
├── postgres-init/             creates the extra Postgres databases on first boot
├── up.sh                      one-command quickstart (compose up + bootstrap + seed)
├── scripts/
│   ├── bootstrap.sh           creates the org/admin user/portal config (idempotent)
│   ├── seed.sh                populates developers/APIs/keys at a chosen scale
│   ├── reset.sh                removes what seed.sh created (or the whole stack, --full)
│   └── lib/                    shared shell helpers seed.sh/bootstrap.sh/reset.sh use
└── docs/                       you are here
```
