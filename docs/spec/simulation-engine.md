# Spec: Ambient simulation engine — an AFK world that generates tenant *and* agent events over time

> Status: **ready for /to-tickets** (grill-spec). Design decisions recorded in
> [ADR 0011](../adr/0011-ambient-world-simulation-simulated-agent.md), which
> supersedes [ADR 0005](../adr/0005-simulation-and-time-model.md) decision 1 and
> un-defers §10 (agent side).

## Problem Statement

The seed manufactures a rich board *as of today*, but nothing drives the world
forward after that. Two gaps:

1. **No live tenant driver** — the pure behaviour engine (`Simulation.Behaviour`)
   is only ever invoked by the seeder over historical dates. As real time passes
   the seed horizon, no new payments arrive, and the midnight sweep books every
   tenant's new `RentFellDue`s — so even "reliable" tenants rot into fake arrears.
2. **No agent at all, live** — termination notices and vacating exist only as
   seeder-planted history or (hypothetically) human clicks. There is no
   interactive agent UI, and building one first is not the priority.

The user wants an **AFK** project: a world that evolves realistically on its own
— payments, arrears, notices, tenants vacating — without day-to-day management.

## Solution

A **planner**: a top-level Oban job that computes each tenancy's deterministic
*world-line* ahead of time and enqueues the not-yet-happened events as scheduled
Oban jobs. Tenant payments come from the existing pure behaviour engine; agent
actions (notice, vacate) are **derived** from the computed arrears trajectory via
a deterministic agent archetype. The existing midnight sweep continues to advance
`RentFellDue` unchanged.

## User Stories

1. As a demo viewer, I want the board to keep evolving over real days without my
   intervention, so that it stays interesting AFK.
2. As a demo viewer, I want reliable tenants to keep paying as time passes, so the
   board doesn't decay into universal fake arrears.
3. As a demo viewer, I want tenants who fall far enough behind to receive a
   termination notice and eventually vacate, so the exit lifecycle is exercised
   without me driving it.
4. As the developer, I want the entire future to be a deterministic function of the
   catalogue + dates, so that a re-plan or re-seed reproduces the same world.
5. As the developer, I want the planner to compute each tenancy's world-line once
   after seed and enqueue only the future events as scheduled jobs, so that runtime
   jobs are dumb dispatches with no arrears read.
6. As the developer, I want the enqueue idempotent on `{tenancy_id, event}` — safe
   because each scheduled event kind occurs at most once per tenancy in v1 — so a
   re-run never double-schedules and the aggregate's own dedupe backstops it.
7. As the developer, I want the agent's notice threshold to be a per-scenario
   archetype, so the board can show both a strict and a lenient response.
8. As the developer, I want a noticed tenant's vacate date derived as `E + overstay`,
   so the aggregate's overstay charge is exercised without hand-authored dates.
9. As an operator, I want the reset-to-healthy cron (issue #92) to purge planned
   jobs before re-seeding, so stale jobs never fire against a fresh world.

## Implementation Decisions

- **Reopens [ADR 0005](../adr/0005-simulation-and-time-model.md) decision 1**: the
  simulation drives agent-side events (notice, vacate), not only tenant + time.
  The deliverable shifts from "play the agent" to "watch a simulated world";
  a human-override mode is deferred, not precluded.
- **Deterministic world-line.** The entire trajectory (payments → arrears →
  agent reaction → vacate) is a pure function of the catalogue + dates. No runtime
  RNG. Reproducible; a re-plan yields the same schedule.
- **Planner = realizer, not runtime decider.** It folds each tenancy's world
  forward, finds the dates events occur, and enqueues future ones as scheduled
  Oban jobs. It does not decide anything at job-run time.
- **Midnight sweep unchanged.** The built `Sweep.CronWorker` → `TenancyWorker` →
  `CatchUp` still advances `RentFellDue` at `@daily`. All same-midnight booking is
  acceptable — a planned **payment** job and the midnight sweep may target the same
  tenancy on the same date, and it does not matter which books first. Two independent
  reasons make the order immaterial (issue #161):
  - **Decisions are pre-made, never read at runtime.** Notice/vacate are derived at
    *plan time* by the deterministic world-line, not from a runtime arrears read — so
    a runtime job is a **dumb dispatch** of a pre-decided command. No same-day booking
    order can change any agent decision, because nothing at runtime consults the
    balance to decide.
  - **The fold is order-independent for the reads that matter.** A `RentPaymentRecorded`
    and a `RentFellDue` write to **disjoint** aggregate-state fields: the charge writes
    the `charges` list **and** the `due_through` pointer, while the payment touches
    neither — it writes `payments_total_cents`/`applied_payment_ids`. So their two
    `evolve/2` steps commute, and the folded state — and therefore `balance_cents`, the
    FIFO `oldest_unpaid_due_date`, and `days_behind` — is identical whether the charge
    or the payment folds first. `balance_cents` is a sum-of-charges minus payments, and
    the FIFO oldest-unpaid walks the `charges` list (which the payment never touches);
    `days_behind` is derived from that oldest-unpaid date (via `Tenancy.days_behind/2`),
    so an order-independent oldest-unpaid makes `days_behind` order-independent too. The
    booked **arrears** come out the same either way. (Regression:
    `test/latchkey/simulation/same_day_ordering_test.exs`.)

  Because both hold, the runtime needs **no** explicit per-day dispatch sequence; the
  implicit "same-midnight acceptable" is safe as-is. The world-line still pins the
  intra-day order it *derives* against (a period's charge is included on its due date,
  `due_on <= date`; a payment folds after a same-day notice, `occurred_on <
  notice_date`) — that is a plan-time ordering of the derivation, separate from and
  unaffected by the runtime dispatch order this bullet concerns.
- **B2 — derived reactive agent (un-defers ADR 0005 §10).** The simulated agent
  has a deterministic archetype (e.g. `strict` = notice at L7 eligibility / 14
  days behind, `lenient` = 30). Its notice/vacate dates are **derived from the
  computed arrears trajectory at plan time** — realism without a runtime feedback
  loop into the pure engine.
- **Finite evolving population; freshness by auto-reset, not perpetual generation.**
  The ~100 seeded tenancies play out their lifecycles and the board slowly
  quiesces; freshness comes from the config-guarded reset-to-healthy cron
  (issue #92), so "AFK" is satisfied by automation. Perpetual re-letting of
  vacated properties is deferred.
- **One world-line function, cut at `today`.** A pure function turns a scenario
  (tenant archetype + agent archetype + commence date) into the *full* dated event
  list, past and future. `property_ref` rides along as **identity only** — it labels
  which premises the derived events attach to (per [ADR 0008](../adr/0008-property-tenant-identity-and-property-balance.md));
  it is never a behavioural input to the trajectory, so the derivation tuple stays
  `(tenant archetype × agent archetype × commence date)` everywhere. Events ≤ today → the seeder replays
  now (backhistory); events > today → the planner schedules. Seed and live stop
  being two code paths — they're one derivation cut at a different date. B2 lets
  the catalogue **drop hand-authored notices/keys-returns**: agent events are
  derived, not planted.
- **Plan-once after seed.** Deterministic + finite + no intervention ⇒ the whole
  remaining future is known at seed time. The planner enqueues every future event
  once, as scheduled Oban jobs at their date; runtime jobs are dumb (dispatch the
  pre-decided command / append the payment, no arrears read). Idempotent on
  `{tenancy_id, ref}`, where `ref` is a **stable per-occurrence world-line id**: the
  once-per-lifecycle agent actions use their event name (`notice`, `vacate`), while a
  recurring **payment** — the one event kind that occurs many times per tenancy
  (issue #200) — uses its stable per-period `payment_id`, so distinct payments never
  collapse into one. The aggregate's / payment ACL's own dedupe backstops it. No
  recurring decider cron.
- **Reset carries a seed generation.** Reset (#92) purges *scheduled* planned jobs
  and replans — but a job Oban has already **claimed** (moved to `executing`) is
  past deletion and would otherwise dispatch a stale command into the fresh seed.
  So each planned job is stamped with the **seed generation** it was planned under;
  reset advances the generation, and the dumb runtime dispatch checks its stamp
  against the current generation and **no-ops if stale**. This closes the
  reset-vs-claimed-job race without depending on purge timing.
- **Exit lifecycle needs no new machinery.** Dispatching `ReturnKeys` at the
  vacate date already drives catch-up-to-`E`, the overstay charge, and
  `TenancySettled` → Terminal inside the aggregate (exit-settlement spec, story
  18). So the sim drives the full exit with the two existing commands it already
  uses: `GiveTerminationNotice` (agent) → `ReturnKeys` (tenant vacates).
- **Agent + vacate model (all derived, deterministic).**
  - *Agent archetype = a notice threshold*, per scenario for demo variety. Two for
    v1: `strict` (notice the day `days_behind` crosses L7 = 14) and `lenient` (30).
    A tenant who never crosses their agent's threshold is never noticed — reliable
    and chronically-late-but-current tenants never exit.
  - *Termination date* `E = notice_date + 14` (s88 statutory minimum).
  - *Vacate date* `V = E + overstay`, overstay a deterministic per-tenant offset
    (0 for a compliant departer; seeded-positive for arrears hold-overs, `V ≥ E` —
    the aggregate's overstay charge then bites per the exit spec).
  - *v1: noticed ⇒ vacates* at `V`. No curing (deferred §10).
- **Interesting states emerge from `(tenant archetype × agent archetype × commence
  date)`.** The catalogue still *chooses* combos + commence offsets engineered to
  sit at a chosen state *today* (ADR 0005 dec 9 / ADR 0007) — but the agent events
  are now derived, not planted.

## Testing Decisions

- **The world-line is the seam.** It's a pure function `(scenario, dates) →
  [dated event]`; test it directly for determinism (same input → identical
  output, including a re-plan reproducing the same schedule) and for the derived
  agent decisions (a `strict`/`lenient` archetype over a known arrears trajectory
  yields the expected notice date, `E`, and `V`). No infrastructure needed — this
  is where the archetype logic lives, mirroring the existing pure `Behaviour`
  tests.
- **Planner enqueue as behaviour, not internals.** Assert that planning a scenario
  inserts scheduled Oban jobs at the right dates for the future slice only (past
  events are not enqueued), and that a second plan run inserts no duplicates
  (idempotency on `{tenancy_id, event}`). Use Oban's testing mode; assert on
  enqueued jobs, not on dispatch side effects.
- **Reset-generation guard.** Cover the reset-vs-claimed-job race: a planned job
  stamped with generation *N*, executed after a reset has advanced the generation
  to *N+1*, must no-op (dispatch no command); a job whose stamp matches the current
  generation dispatches normally.
- **Exit falls through existing tests.** The notice→vacate→settle path is already
  covered by the exit-settlement suite; the sim only needs to prove it dispatches
  `GiveTerminationNotice` / `ReturnKeys` at the derived dates — not re-test
  settlement.
- **Prior art:** `Simulation.Behaviour` pure tests; the seeder's Seam-1 tests
  (payment → ACL-1 → `RentPaymentRecorded`); the exit-settlement aggregate tests.

## Out of Scope

- **Human-override / interactive agent mode** — deferred; reintroducing
  interactivity is a later, additive decision.
- **Tenant curing after notice / repayment-plan compliance** — the other half of
  ADR 0005 §10; not required for the notice→vacate happy path.
- **Perpetual re-letting / self-sustaining population** — vacated properties stay
  dark until reset; gated on wanting a forever-running board.

## Further Notes

All grill branches resolved. The build splits roughly into: (1) the **world-line**
pure function (derives agent events from `tenant × agent archetype`, folds arrears);
(2) rework the **catalogue/Projection** to derive rather than plant agent events;
(3) the **planner** Oban job (plan-once, idempotent scheduled enqueue, seed-generation
stamp) + the dumb runtime dispatch jobs (generation-guarded); (4) wiring the reset
cron (#92) to purge planned jobs + advance the seed generation.
