# 0001 — Domain-first, Ash-native event sourcing (AshCommanded)

Status: **on hold** — the AshCommanded choice was rejected after a go/no-go smoke test; see [ADR 0002](0002-ash-commanded-nogo-foundation-parked.md). The domain-first framing below still stands; the AshCommanded-specific design is **historical context only — do not build on it**.

> **⚠️ Historical — do not build on AshCommanded.** Everything below is the
> original AshCommanded proposal, which the go/no-go smoke test **reversed**
> ([ADR 0002](0002-ash-commanded-nogo-foundation-parked.md)). It is retained as the
> record of what was decided and why, **not** as current guidance.

Latchkey is first a **DDD / domain-modelling** exercise — the tenancy lifecycle, the
arrears gate, the Accounts ↔ PM anti-corruption seam. **Event sourcing is a
supporting implementation**, chosen because it makes the append-only, auditable tribunal
timeline (domain-model.md §1) fall out almost for free. This ADR **proposed** building it
**Ash-native via [AshCommanded](https://github.com/accountex-org/ash_commanded)** — a
declarative CQRS/ES extension wrapping the **Commanded** library, with **Commanded's
Postgres EventStore** as the source of truth. *(That proposal was later reversed — see
[ADR 0002](0002-ash-commanded-nogo-foundation-parked.md).)*

## Why AshCommanded

The domain model is already written in CQRS/ES vocabulary, and AshCommanded maps it
almost 1:1 with **no doc rewrite**:

| domain-model.md | AshCommanded / Commanded |
|---|---|
| §4 Tenancy aggregate + fold | Commanded aggregate + `apply/2` |
| §5 invariants L1–L8 refuse the command | command handler returns `{:error, …}` |
| §3 events | `events` DSL |
| §7 arrears + timeline projections (disposable read models) | `projections` → Ash resources |
| §8 ACLs (translate external → emit own) | `event_handlers` / Reactor process managers |
| optimistic concurrency | Commanded expected-version per aggregate stream |

Decisive point: §7 argues the L7 arrears gate must be computed **write-side in the
aggregate**, never off the async projection. Commanded's CQRS split makes that
**structural, not a discipline** — the aggregate decides from its own fold; the
projection is a separate async read model that cannot be gated on synchronously. The
framework encodes the exact argument the model makes.

## Considered and rejected

- **AshEvents** — dual-writes to normal resource tables (**current state**) with
  events as an audit log + replay-by-re-running-actions. That's
  audit-log-over-current-state, **not** fold-as-truth; adopting it would force
  current-state caveats onto §4/§7. Rejected.
- **AshStateMachine** — stores a status column and **mutates it in place**: a
  competing current-state source of truth. Rejected. (The §4 state machine survives
  as domain rules over derived aggregate state.)
- **Events-as-resources, hand-rolled in Ash** — full control and fold-as-truth, but
  it's the manual plumbing that cuts against the domain-first priority. Rejected as
  primary.
- **Hand-rolled, frameworkless ES core** (original §2 framing) — **parked, optional
  descent** (§10), not the spine. If pursued it's a clean-slate rewrite, possibly in
  **Go** (less batteries → the storage mechanics are visible), so the Ash build pays
  for no speculative peelability seams.

## Consequences

- Domain model (§4, §7) would need **no rewrite** — AshCommanded was expected to realise it as written. *(This claim was **falsified** by the smoke test — see ADR 0002.)*
- **Maturity risk accepted.** AshCommanded is **v0.2.0**, by a community org (not
  core Ash). Expect rough edges / thin docs / possible missing features; acceptable
  for a learning sim, and dropping to raw Commanded when the wrapper leaks is itself
  instructive.
- Adds infrastructure: **Commanded + its EventStore** (a separate event-store schema
  with its own migrations) alongside AshPostgres for the read models.
- The "feel the raw ES mechanics" goal is **deferred** to the optional Go descent
  (Commanded also hides the storage layer).
