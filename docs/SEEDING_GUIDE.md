# Seeding Guide

`scripts/seed.sh` populates the Classic Developer Portal (inside the Tyk
Dashboard) with developers, APIs, policies, catalogue entries, keys, and
pending key requests — a realistic source for `edp-migrate` to migrate.

Run `scripts/bootstrap.sh` once first (or just use `./up.sh`, which does
both). It's idempotent — safe to re-run, and `seed.sh` reads the
credentials it writes to `.runtime.env`.

## Basic usage

```sh
scripts/seed.sh --scale small           # 5 developers, 1 API per auth type
scripts/seed.sh --scale medium          # 25 developers, 2 APIs per auth type
scripts/seed.sh --scale large           # 100 developers, 3 APIs per auth type
scripts/seed.sh --scale small --dry-run # print what would happen, make no API calls
```

Run it again (with the same or a different `--scale`) to *add* more data —
it doesn't clear anything first. Use `scripts/reset.sh` to clear.

## Scale presets

| Preset | Developers | APIs per auth type | Keys per developer | Pending requests |
|---|---|---|---|---|
| `small` (default) | 5 | 1 | 1 | 2 |
| `medium` | 25 | 2 | 2 | 5 |
| `large` | 100 | 3 | 3 | 15 |

Every value is individually overridable:

```sh
scripts/seed.sh --developers 50 --apis-per-type 1 --keys-per-developer 4 --pending-requests 10
```

## Controlling *type* — auth-type coverage

`--auth-types` takes a comma-separated subset of the classic auth types
`edp-migrate` has distinct handling for:

| Auth type | What it demonstrates in a migration |
|---|---|
| `keyless` | No credential at all — migrates cleanly, no key to adopt. |
| `authToken` | The classic default (a plain bearer token) — the most common real-world case. |
| `basic` | HTTP Basic Auth. |
| `hmac` | Signed requests. EDP's own Product-creation validation **rejects this auth type outright** — migrates as a documentation-only Product by design, not a bug (see "Dead ends by design" below). |
| `jwt` | Shared-secret JWT (see note below — this is deliberately *not* DCR-registered). |
| `oauth` | Tyk-native OAuth 2.0. Same EDP rejection as `hmac` — documentation-only Product. |
| `openid` | OpenID Connect. Same EDP rejection again. |
| `mutualTLS` | Static mutual TLS. Flagged for manual review — no migration strategy exists yet. |
| `other` | No auth flag configured at all — a deliberately ambiguous/broken classic API, to reproduce `edp-migrate`'s own "needs manual review" finding. |

Default is all nine. Example — just the two most common real-world cases:

```sh
scripts/seed.sh --scale medium --auth-types keyless,authToken,basic
```

### Dead ends by design, not bugs

If your run includes `hmac`, `oauth`, `openid`, or `other`, don't be
surprised when `edp-migrate`'s discovery/migration reports flag them as
"documentation-only Product" or "needs manual review" — EDP's own
Product-creation validation rejects these auth types outright
(confirmed live), and there's no credential-adoption path for a Product
that was never created as a real, subscribable one. This is the tool
correctly surfacing a genuine EDP limitation, not something seed.sh got
wrong.

### The seeded `jwt` API is deliberately not DCR-registered

`edp-migrate` has a separate, working migration path for JWT APIs
registered via Dynamic Client Registration (DCR) against an external IdP
(this stack's own Keycloak, for instance) — but a DCR-migrated Product is
then **permanently excluded from Cutover and Decommission** (Phase 5):
there's no staged classic-side object to deactivate/delete for it. The
seeded `jwt` API instead uses a plain shared-secret HMAC-signed JWT config,
specifically so it *can* be carried all the way through Cutover and
Decommission in [MIGRATION_WALKTHROUGH.md](MIGRATION_WALKTHROUGH.md). If
you want to see the DCR path too, configure it by hand against Keycloak —
outside what `seed.sh` sets up automatically.

### mTLS keys are catalogue placeholders, not real TLS credentials

A genuine mutual-TLS credential needs a real certificate uploaded to the
Gateway/Dashboard cert store and referenced by fingerprint. `seed.sh`
issues a "key" against the seeded `mutualTLS` policy so the catalogue
entry has *a* subscriber to migrate, but it was never a real TLS
handshake credential — fine for exercising `edp-migrate`'s migration
logic, not something you can proxy real mTLS traffic through.

### Rate/quota tiers are deliberately varied

Every seeded policy cycles through one of three different rate/quota
profiles. This matters: `edp-migrate`'s plan-tier computation collapses
every classic policy into a single "Standard" tier if they all share the
same rate/quota (confirmed live) — real variance is what makes the
Migration phase's multi-tier output worth looking at.

### Basic Auth's admin-issued key response

If you're reading raw API responses while debugging: for a `basic` auth
policy, the admin-issued key response's `RawKey` field holds the
**username**, and `Password` holds the actual password — backwards from
what the field names suggest.

## Pending requests vs. issued keys

A developer either gets left with one **unapproved pending key request**
(consuming your `--pending-requests` budget) or gets `--keys-per-developer`
keys issued directly — never both in the same seed.sh run, so the pending
count in `edp-migrate`'s discovery report matches `--pending-requests`
exactly. Keyless APIs are excluded from both — the Dashboard itself
rejects a key request or admin-issued key against a keyless API.

## Resetting

See the README's "Resetting" section — the short version is: use
`scripts/reset.sh --full` (not the plain form) as soon as you've run
`edp-migrate plan`/`execute`, not just `inventory`, against the seeded
data.
