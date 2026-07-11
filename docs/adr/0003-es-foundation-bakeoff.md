# 0003 — ES foundation bake-off: raw Commanded chosen

Status: **accepted** — resolves the "when unparked" fork in [ADR 0002](0002-ash-commanded-nogo-foundation-parked.md)
and **supersedes [ADR 0001](0001-domain-first-ash-native-es.md)** on the *tool*
(0001's domain-first framing still stands). Decision: **Option 1, raw Commanded.**

## What we did

Spiked **both** foundations end-to-end on a throwaway branch (`spike/es-bakeoff`)
over an *identical* slice and an *identical* shared decision core
(`lib/spike/tenancy_core.ex`). The discriminating test is the **L7 arrears gate**:
`TerminationNoticeGiven` must be refused unless `days_behind ≥ 14`, computed
**write-side from the fold** — the exact thing AshCommanded couldn't express.

- **Option 1** — raw Commanded + its Postgres EventStore, Ash for the read model.
- **Option 2** — events-as-resources in pure Ash (event-log resource + hand fold).

**Both pass** the gate (refuse <14d, accept ≥14d, FIFO payment resets the clock),
both seeded end-to-end (`mix spike.seed both`) to identical read models. Full
evidence: `spike/SCORECARD.md`. Headline finding: the domain logic is **framework-
independent** (188 shared LOC) — every other difference is plumbing.

## The decision hinges on one axis: seam weight

Building both moved this from a clear lean to a genuinely close call, because two
facts cut *toward* Option 2:

1. **The domain is framework-independent** — both spikes call the same pure
   `TenancyCore`. Commanded ends up *hosting* functions we already wrote; we adopt
   it for the event store + router + **process managers**, not its aggregate model.
2. **Much of the model is aggregate-internal.** Most of L1–L8 are single-`Tenancy`
   invariants (no cross-aggregate coordination). ACL-2 is an explicit stub. ACL-1 is
   idempotent one-way translation — a simple handler, not a saga.

So the whole decision reduces to: **how much genuine cross-aggregate saga
coordination does the payments seam need?**

- **Thin seam** (mostly internal invariants + one idempotent ACL-1) → Option 2 wins;
  Commanded is a second DB + 3 deps + 13 files of ceremony to host an event log.
- **Coordination-heavy seam** (§10 termination ↔ repayment-plan ↔ void as a
  cross-entity dance, future Accounts↔PM sagas) → Option 1 wins; process managers
  are purpose-built for it and Ash has **no native equivalent**.

## Decision & rationale

**Go with Option 1 (raw Commanded).** We're betting the seam is coordination-heavy
enough to want process managers rather than hand-rolled GenServer sagas — the seam
*is* the project. Two structural bonuses seal it:

- **Fold-as-truth is structural, not disciplined** — Commanded cannot run `execute`
  off unfolded state. Option 2's gate reads the fold only because we route through
  `run/4`; nothing stops a future action skipping it. Given AshCommanded was
  rejected (ADR 0002) for exactly that gap, we don't want to re-admit it as a
  convention.
- **The aggregate is purely unit-testable** — no DB (`commanded_aggregate_test`:
  4 tests, 0.01s), vs Option 2 needing the Postgres sandbox.

## What we accept by not taking Option 2

A **second Postgres DB** (event store, own create/init/migrate lifecycle), **3
deps**, more moving parts, and **hidden storage** — so the "feel the raw mechanics"
goal stays deferred to the optional Go descent (ADR 0001 §10). Acceptable for a
learning sim; dropping to raw Commanded internals when the need arises is itself
instructive.

## Next steps (not yet done — spike stays for the code tour)

- Keep `spike/` + `lib/spike/` until the code tour has traced ACL-1 and the
  termination/void saga through it (this is where the seam-weight bet gets felt).
- Then: promote the Commanded shape into the real tree, wire `Spike.Commanded.App`
  + projector into the supervision tree, and delete the pure-Ash spike.
- Revisit if the code tour reveals the seam is thinner than assumed — the bet above
  is falsifiable, and Option 2 remains a documented, working fallback.
