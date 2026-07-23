# 0011 — Ambient world simulation: the sim drives the agent too

Status: **accepted** — supersedes [ADR 0005](0005-simulation-and-time-model.md)
decision 1 (the "simulated tenant, human agent" scope line) and **un-defers**
ADR 0005 §10's reactive-behaviour deferral, for the agent side only. Full design
in [docs/spec/simulation-engine.md](../spec/simulation-engine.md).

## Context

ADR 0005 decision 1 drew the scope line at "the sim drives time + the tenant;
everything agent-side is the human end-user" — the deliverable was *"walk in and
play the agent."* But the interactive agent UI to *create* notices/keys-returns
live was never built, and the project's priority is an **AFK** demo that evolves
on its own. Building the gameplay first is not worth it. New information ⇒ reopen.

## Decision

The simulation drives **agent-side events too** — termination notices and vacating
— not just time + the tenant. The deliverable shifts from *"play the agent"* to
*"watch a fully-simulated world evolve, AFK."* A human-override mode is **deferred,
not precluded** (the shift is reversible).

The simulated agent is a **deterministic archetype** (a notice threshold: `strict`
= notice at L7/14 days behind, `lenient` = 30) whose notice date — and the derived
vacate date `V = E + overstay` — are **computed at plan time from the deterministic
arrears trajectory**, not read from live state at run time. This is the reactive
feedback loop ADR 0005 §10 deferred, but because the whole world-line is
deterministic it is computed *ahead of time*: realism without a runtime feedback
loop back into the pure engine. Decision 8's determinism/reproducibility and the
purity of the tenant engine are preserved.

## Considered options

- **Keep ADR 0005 decision 1 (human agent) and build the interactive UI first** —
  rejected: it's the larger build and defeats the AFK goal.
- **Scripted agent (author notice/keys dates per scenario)** — rejected: a finite
  authored horizon that doesn't sustain open-ended AFK, and strictly weaker than
  what the seeder already hand-plants.

## Consequences

- Still deferred (ADR 0005 §10, other half): **tenant curing after notice /
  repayment-plan compliance.** Consequently the **"notice-issued-then-tenant-paid"
  void-candidate** board state is unreachable until curing is un-deferred.
- The catalogue **drops hand-authored** notices/keys-returns — agent events are
  derived from `(tenant archetype × agent archetype × commence date)`.
- Freshness stays with the finite-population + reset-to-healthy model (issue #92);
  perpetual re-letting remains deferred. **This "future payments left to the reset"
  half is amended by [ADR 0012](0012-schedule-future-payments-plan-once.md)** —
  future payments are now scheduled plan-once too (issue #200), because the reset
  alone could not keep reliable tenants paying between re-anchors.
