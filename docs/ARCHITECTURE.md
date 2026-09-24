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
adopted as credentials, and so on. `MIGRATION_PLAN.md`, in the core tool's
own (private) repo — not part of this directory — is the full design
document for exactly how each resource type maps; that repo's own README
is also where every classic auth type's exact EDP treatment is documented
(this directory's [SEEDING_GUIDE.md](SEEDING_GUIDE.md) covers the same
ground from the "seeding data to demonstrate it" angle instead).

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
                    │  (published    │  writes EDP — the tool under test,
                    │  image, pulled)│  pulled from Docker Hub/ghcr.io
                    └────────────────┘
```

All three logical databases (the Classic Dashboard's `tyk_analytics`, EDP's
`tyk_portal`, and Keycloak's own `keycloak`) live in **one** Postgres
instance, in separate databases — the one-shot `tyk-postgres-init`
service creates the latter two over the network once Postgres is healthy
(`tyk_analytics` is created by the `POSTGRES_DB` environment variable
already). Both `tyk-ent-portal` and `keycloak` depend on it completing
successfully before they start, so there's no race with either database
not existing yet.

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
├── docker-compose.yml         the full stack, pulling edp-migrate as a published image
├── docker-compose.mongo.yml   optional override: Mongo instead of Postgres
├── confs/                     env files for each Tyk component
├── up.sh                      one-command quickstart (compose up + bootstrap + seed)
├── scripts/
│   ├── bootstrap.sh           creates the org/admin user/portal config (idempotent)
│   ├── seed.sh                populates developers/APIs/keys at a chosen scale
│   ├── reset.sh                removes what seed.sh created (or the whole stack, --full)
│   └── lib/                    shared shell helpers seed.sh/bootstrap.sh/reset.sh use
└── docs/                       you are here
```
