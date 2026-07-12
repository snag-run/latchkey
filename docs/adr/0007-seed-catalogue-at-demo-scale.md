# 0007 — Seed catalogue at demo scale: tenant identity + periodic reset

Status: **accepted** — extends the scenario catalogue of
[`0005`](0005-simulation-and-time-model.md) decision 9 (issue #44) from three
hand-crafted tenancies to a ~100-tenancy board for the inspector. Pins the two
durable decisions scaling surfaces; the faker/generator mechanics are implementation
detail (the seeder), not recorded here.

## Context

The scenario catalogue proved the *seed-through-the-live-seam* approach with three
legible, hand-authored tenancies. Filling a board for the developer/PM inspector means
~100 tenancies with **human-legible identity** (a tenant name, a property address) and
a **realistic spread** of arrears/exit states. Two questions the three-scenario
catalogue never had to answer fall out of that, and both are durable/cross-cutting
rather than feature-local:

1. **Where does tenant identity live?** The domain today has no name/address anywhere —
   commands, events, and the `Arrears` read model all key off a `tenancy_id` slug. A
   board of 100 slugs is unreadable, so identity has to come from somewhere.
2. **How does a long-running demo store avoid drift?** Every catalogue date is an offset
   from `today` (decision 9), so a store seeded once and left running ages badly:
   planted notices slide past their termination dates, arrears counters climb without
   bound, and the board stops reading as the curated set of states it was built to be.

## Decisions

### 1. Tenant identity lives in a disposable Directory read model — never the event log

Faker-generated name + property address live in a **`Directory` read model** (an Ash
resource keyed by `tenancy_id`, same Postgres schema as `Arrears`), populated at seed
time. It is rendered by a keyed lookup merged in Elixir — **no cross-schema join** into
the event store, because you never render identity off the raw log. The write model
(the `Tenancy` aggregate, which reasons only about rent) never carries a name it does
not use.

The reason it stays out of the log is the log's defining property: events are
**immutable and permanent**. PII in an append-only log is unredactable and
un-erasable — the canonical event-sourcing footgun — and this codebase is our
reference for ES done right. Identity is disposable, rebuilt from the seed; the
tribunal-evidence log stays PII-free.

- *Rejected — name/address as fields on `CommenceTenancy` / `TenancyCommenced`.*
  Simplest to render (identity travels with the commence fact, no second resource). The
  seed data is faker-fake so there is no *real* erasure risk — but it puts PII in the
  permanent log and bloats the aggregate with a read-only concern, which is exactly the
  modelling reflex we do not want to teach. The cross-schema-join objection that made
  this look cheaper turned out to be a myth: a sibling read model is same-schema,
  Ash-to-Ash, merged in Elixir.

**Flagged / deferred:** the `Directory` is a **seed-time fixture, not event-sourced**,
so tenant identity is deliberately *not* part of the evidence log. If real tenancy
identity ever needs to be first-class tribunal evidence, that is a separate decision (a
dedicated identity stream / bitemporal identity record), explicitly out of scope here.

### 2. Deterministic faker — seeded RNG keeps the catalogue reproducible

Decision 8 of ADR 0005 makes the catalogue byte-for-byte reproducible (stable slugs,
seeded jitter). Faker's default RNG is process-global and non-deterministic, which
would break that guarantee. Faker is therefore seeded **deterministically per tenancy**
(a seed derived from the tenancy's stable slug), so a re-seed of a fresh store
reproduces identical identities. Slug ids stay stable and legible.

### 3. The demo store is periodically reset-to-healthy via a config-guarded Oban cron

A monthly `Oban.Plugins.Cron` job wipes the store and reseeds a fresh board anchored to
the new `today`, so the board stays curated without anyone operating it. The runtime
reset — pause the projector → reset the EventStore streams/subscriptions → truncate the
read tables (`Arrears`, `Directory`) → restart the projector from `:origin` → reseed —
is designed as a single operation, **guarded behind a config flag** so it can only fire
in the demo environment and never a store with data worth keeping.

- *Rejected — leave reset as the manual `mix ecto.reset && mix run priv/repo/seeds.exs`
  convention.* Fine for a developer at a keyboard, but the goal is an unattended demo
  that stays healthy on its own; a manual convention drifts precisely when no one is
  watching.
