# Latchkey

A learning project in **event sourcing + Domain-Driven Design**, built as a
**simulation** of the payments seam in residential property management (NSW).

## What it is

Latchkey models the boundary between two bounded contexts:

- **Property Management (PM)** — the **core** domain: tenancies, lease terms,
  expected rent, and therefore **arrears**. This is the deep context.
- **Accounts** — a thin **supporting** edge that emits payment facts (money
  received, reversals).

The interesting problem is how a **payment fact born in Accounts crosses into PM
and reconciles into arrears** (`arrears = expected − received`) — translated at an
anti-corruption layer, never folded raw across the seam.

**Thesis / deliverable:** a **tenancy timeline** — a complete, tamper-evident
history of a tenancy (rent falling due, payments, notices, corrections) legible
enough to serve as **evidence in an NCAT (tribunal) arrears case**. That timeline is
the payoff of an append-only event log with correction-by-compensation (never
mutation).

It's a **simulation, not production**: events are seeded, and a tenant-behaviour
engine plus scheduled jobs advance *simulated* time so histories accrue realistically
rather than all at once. Grounded in the NSW Residential Tenancies Act 2010 for
realism — **not legal advice**.

## Design docs (the spec)

The model is worked out in `docs/` and is the spec to build against:

- [`docs/domain-model.md`](docs/domain-model.md) — the deep model: events, the
  `Tenancy` aggregate, invariants, accrual, arrears (the time-based 14-day trigger),
  the two ACLs, and value objects.
- [`docs/context-map.md`](docs/context-map.md) — the subdomain map: what's core /
  supporting / generic, and where the seams (language flips) are.

## Status

Domain modelling is captured in `docs/`. The application itself is currently the
**Phoenix 1.8 + Ash 3 scaffold** — event store, aggregate, and projections are not
yet implemented. Event sourcing will be **hand-rolled** (one append-only Postgres
table) on purpose: the point is to feel the mechanics.

## Stack

Phoenix 1.8 · Ash 3 + AshPostgres · PostgreSQL (Ecto/Postgrex) · Bandit ·
LiveView · Tailwind. (Scheduled-job driver for simulated time — Oban — is planned,
not yet wired up.)

## Getting started

* `mix setup` — install deps, provision the Ash and EventStore databases, build assets, seed
* `mix phx.server` (or `iex -S mix phx.server`) — start the server

Then visit [`localhost:4000`](http://localhost:4000).

Run `mix precommit` before committing — it compiles with warnings-as-errors,
prunes unused deps, formats, and runs the tests.
