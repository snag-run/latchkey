# Spec — Simulation & time model (wall-clock time, simulated tenant, human agent)

> Source of decisions: [ADR 0005](../adr/0005-simulation-and-time-model.md) and
> `docs/domain-model.md` §1/§3/§6/§7/§8. Design issue: #4 (resolved by ADR 0005).
> Amends [ADR 0004](../adr/0004-exit-settlement-events.md) §5 (`recorded_on` reframed).
> Sizing into vertical-slice tickets is a `to-tickets` concern — a suggested cut is in
> Further Notes, not decided here.

## Problem Statement

Today a tenancy only moves when a command is dispatched with an explicit date. There
is no notion of "now", nothing advances time, and nothing produces the payment facts a
tenancy reacts to. So the system can be *driven* by hand, one command at a time, but it
cannot **build a history on its own** — you cannot open the app and see a board of
tenancies that have been accruing rent, receiving (or missing) payments, and drifting
into arrears over weeks. The `Arrears` read model makes this concrete and wrong:
`days_behind` is measured as-of the *last booked due date*, so an idle tenant's arrears
counter is **frozen** — a tenant who stopped paying looks paid-up until something pokes
them. For a project whose deliverable is a tribunal-grade arrears timeline, "time
passes, rent falls due, money arrives or doesn't, and arrears build" is the engine that
makes every other feature demonstrable — and it doesn't exist yet.

## Solution

A simulation that drives exactly two things — **time** and **the tenant** — while the
**human user plays the agent**. Per ADR 0005:

- **Wall-clock time, Sydney.** "Now" is today's date in `Australia/Sydney`, read at one
  edge (`Latchkey.Clock.today/0`). No stored sim-clock, no speed knob; domain code stays
  pure by taking `as_of` explicitly.
- **A daily Oban sweep** advances lazy catch-up (`RentFellDue`) for every live tenancy,
  so a tenant who stops paying becomes **visible** in arrears rather than frozen.
- **`days_behind` computed on read** as `today − oldest_unpaid_due_date`, so an idle
  arrears counter climbs correctly with no new event.
- **A tenant-behaviour engine** emits `PaymentReceived` facts — deterministic archetypes
  (pays on time / late / short / misses) — **through the ACL-1 seam** into
  `RentPaymentRecorded`.
- **Seeding** manufactures backhistory by replaying that same engine over past dates,
  producing a **scenario catalogue** of tenancies engineered to sit at interesting
  states today (paid-up, 20-days-behind-no-notice, notice-then-paid void candidate).
- **The agent is the human user.** The app *surfaces* arrears-termination eligibility as
  an affordance; the user decides whether and when to act. L7 remains the write-side gate.

## User Stories

1. As a property manager using the sim, I want tenancies to accrue rent as time passes, so that arrears build up on their own instead of only when I hand-enter a command.
2. As a property manager, I want a tenant who has stopped paying to show as *increasingly* in arrears each day, so that a silent non-payer is visible rather than appearing paid-up.
3. As a property manager, I want `days_behind` to reflect *today*, not the last booked due date, so that the number I rely on for the 14-day ground is accurate.
4. As a property manager, I want the "issue arrears termination notice" option to light up only once a tenant is ≥14 days behind, so that I am guided to a lawful action.
5. As a property manager, I want to *choose when* to issue the termination notice after it becomes available (day 14, week 3, or never), so that the decision stays mine, not the system's.
6. As a property manager, I want the system to refuse a termination notice if the tenant paid down their arrears since the button lit up, so that a stale affordance can never authorise an unlawful notice.
7. As a property manager, I want to void a notice, or agree a repayment plan, as my own decisions, so that the agent side of the lifecycle reflects real human judgement.
8. As a property manager, I want tenants to pay on time, late, short, or not at all, so that the timelines I study look like real rent ledgers.
9. As a property manager, I want a tenant who is occasionally late and then catches up, so that not every arrears case is a straight-line decline.
10. As a property manager, I want simulated payments to arrive as Accounts facts that cross into arrears through the anti-corruption layer, so that the seam the project exists to study is actually exercised.
11. As a property manager, I want to open the app to a board of tenancies already in interesting, varied states, so that I can practise the arrears lifecycle without waiting real weeks.
12. As a property manager, I want at least one seeded tenant sitting just past the 14-day threshold with no notice yet, so that the primary arrears decision is demonstrable on load.
13. As a property manager, I want a seeded tenant who was issued a notice and then paid, so that I can practise voiding a notice.
14. As a property manager, I want the timeline to show *when a fact was true* versus *when it was booked*, so that lazy catch-up and pre-entered notices read correctly as evidence.
15. As a property manager, I want dates computed in Sydney time, so that a payment made in the Sydney morning is never mis-dated to the previous day and the 14-day gate is never off by one.
16. As a developer, I want "now" threaded as an argument through domain code, so that every behaviour and accrual rule is unit-testable with zero infrastructure.
17. As a developer, I want a single place that reads wall-clock time, so that the timezone lives in one spot and the clock is stubbable.
18. As a developer, I want the daily sweep to be idempotent, so that a double-run (or retry) never double-charges a tenancy.
19. As a developer, I want ACL-1 to be idempotent on `source_payment_id` and checkpointed, so that a replay re-folds already-emitted payments rather than re-translating them.
20. As a developer, I want behaviour archetypes to be deterministic (seeded), so that tests and demos reliably reproduce the same timelines.
21. As a developer, I want seeding to reuse the live engine over historical dates, so that seeded history is byte-identical to what the live loop would have produced.
22. As a developer, I want re-running the seed to produce the same catalogue, so that the demo and test fixtures are stable.
23. As a developer, I want the sweep to touch only what it must (book due dates), so that idle tenancies don't incur a daily write just to keep a counter fresh.
24. As a developer, I want the Accounts context to actually produce `PaymentReceived` / `PaymentReversed`, so that the edge is not an empty stub.
25. As a developer, I want a reversal to flow as a negative payment through ACL-1, so that corrections use compensation, not mutation.
26. As a developer building later features, I want the bitemporal envelope present on every event, so that the timeline projection (#5) can render effective-vs-recorded without special-casing.
27. As a property manager, I want a tenant who pays short (partial) some weeks, so that I can see a balance that reduces without clearing the oldest period.
28. As a property manager, I want a reliably-paying tenant in the mix, so that the board isn't uniformly distressed and I can contrast healthy vs. failing tenancies.

## Implementation Decisions

- **`Latchkey.Clock` module** — a single `today/0` returning the current date in
  `Australia/Sydney`. The **only** wall-clock read-site; called by the Oban sweep job
  and the seed script, **not** injected into `decide`/the behaviour engine (those take
  `as_of :: Date.t()`). Adds the `tz` dependency and
  `config :elixir, :time_zone_database, Tz.TimeZoneDatabase`.
- **No stored clock, no speed multiplier.** Domain code remains pure, threading `as_of`.
  Backhistory comes from seeding; as-of views come from read-side replay.
- **Bitemporal envelope retrofit** — every event carries `{effective_date, recorded_on}`
  (Sydney dates). `recorded_on` = wall-clock for live events, seeder-assigned for
  history. Direction is per-event-kind: notices forward-date (`effective ≥ recorded`);
  accrual catch-up ticks lag (`recorded ≥ effective`) — lazy accrual, **not** backdating.
  This is the cross-cutting retrofit ADR 0004 left un-ticketed.
- **Daily Oban sweep** — enumerates live tenancies and, per tenancy, dispatches
  `CatchUp{as_of: Clock.today()}`, booking owed `RentFellDue`s through
  `min(today, effective_end_date)`. Idempotent via the `due_through` pointer. It **never
  issues notices**. Fan-out favours one child Oban job per tenancy (retry isolation /
  observability); the exact shape is an implementation call.
- **`days_behind` on read** — store `oldest_unpaid_due_date` (event-driven); derive
  `days_behind = Clock.today() − oldest_unpaid` at query time. Retire
  `ArrearsProjector`'s `as_of = due_through` (which freezes the counter).
- **L7 stays a write-side invariant** — `decide_termination` re-checks `days_behind ≥ 14`
  from the aggregate fold on the user's click. The eligibility affordance is a
  projection-only read that can be stale-safe (the gate refuses if the tenant paid).
- **Accounts context (stub)** — produces `PaymentReceived` and `PaymentReversed`
  (the two §3 edge events, bitemporal). The behaviour engine is Accounts' sole producer.
- **ACL-1 policy** — translates `PaymentReceived → RentPaymentRecorded` (and
  `PaymentReversed → negative RentPaymentRecorded`). A checkpointed, replay-safe policy
  (its own checkpoint over the Accounts stream), idempotent on `source_payment_id`; fires
  only for tenancy-attributed receipts.
- **Behaviour engine** — a pure function `(profile, schedule, date) → maybe
  PaymentReceived`. Profiles are **deterministic archetypes**
  (`reliable`, `chronically-late(+N)`, `deteriorating`, `sporadic`) expressed as
  parameterised rules + optional explicit per-period overrides + optional **seeded**
  lateness jitter. "Late then catches up" is *scripted* (an authored per-period list),
  not reactive.
- **Seeding** — replays the behaviour engine + `catch_up` over each tenancy's historical
  due/payment schedule (iterating the schedule, not calendar days), so seeded output is
  identical to live. Produces a **named scenario catalogue**, each tenancy an archetype +
  backdated commence date + optional planted agent events, engineered to land at a chosen
  state today. Reproducible via seeded RNG.

## Testing Decisions

A good test asserts **external behaviour**, not implementation — given a profile and a
date, *what payment fact appears*; given a non-paying tenant and a sweep, *does arrears
become visible*; given a stale eligibility flag, *does the write-side gate still refuse*.
Dates are always injected, never read from the wall clock, so every assertion is
deterministic.

- **Seam 1 — pure domain, injected clock (highest; = existing `AggregateTest`).** Unit
  tests for: the behaviour engine (each archetype + seeded jitter + scripted overrides
  produce the expected `PaymentReceived` sequence over a date range); ACL-1 translation
  (`PaymentReceived → RentPaymentRecorded`, reversal → negative); catch-up; and
  `days_behind = today − oldest_unpaid` across boundary dates. No DB, no app.
- **Seam 2 — integration, proven once (= existing `TenancyIntegrationTest` harness +
  `Oban.Testing`).** Tests: the sweep dispatches `CatchUp` for a non-paying tenancy and
  the `Arrears` read model then shows rising `days_behind` (`Oban.Testing.perform_job`);
  ACL-1 is idempotent + checkpointed across a replay (an already-emitted
  `RentPaymentRecorded` is re-folded, not re-translated); a seed run produces the
  expected catalogue timeline; `days_behind` reads as-of today.
- **Prior art:** `AggregateTest` (pure `execute`/`apply`, injected dates) and
  `TenancyIntegrationTest` (full stack through `CommandedApp` + EventStore + projector).
  Reuse both; add `Oban.Testing` for the sweep job. Behaviour + ACL-1 belong at Seam 1.

## Out of Scope

- **Reactive / self-aware tenant behaviour** — a tenant reading its own arrears to catch
  up, or complying with a repayment plan the user agreed. A feedback loop; deferred with
  the §10 repayment-plan-compliance question.
- **A landlord/agent behaviour engine** — never; the agent is the human user.
- **Timeline read-model / UI rendering (#5)** beyond the eligibility affordance needed to
  demonstrate the arrears decision.
- **Hash-chaining / tamper-evidence (#16).**
- **Accounts as a true double-entry ledger** (§10 directional goal); Accounts stays the
  payment-facts edge here.
- **Time-travel controls / a speed multiplier / a stored sim-clock** — explicitly rejected.
- **Exit-settlement accrual** (ADR 0004 / its own spec) — this feeds it `recorded_on` but
  does not build it.

## Further Notes

- **Suggested tracer-bullet cut for `/to-tickets`** (dependencies noted, not fixed):
  1. `Clock` + `tz` + bitemporal envelope retrofit across existing events (write-side
     foundation; smallest tracer).
  2. Oban + daily sweep + `days_behind`-on-read + `ArrearsProjector` fix (depends on 1).
  3. Accounts stub context + `PaymentReceived` / `PaymentReversed` (bitemporal).
  4. ACL-1 checkpointed policy Accounts → PM (depends on 3).
  5. Tenant behaviour-engine archetypes (depends on 4 + `Clock`).
  6. Seed scenario catalogue (depends on 5 + sweep).
- **Sydney timezone is correctness, not cosmetics** — the L7 gate is exact and inclusive
  (s88: "not less than 14 days"); a UTC "today" would drift the boundary by a day for
  ~10 h daily. See ADR 0005 decision 2.
- **Relationships:** resolves design issue **#4** (deliverable was ADR 0005; this is the
  build). Feeds **#5** (the envelope + payment facts are what the timeline renders) and
  supplies the `recorded_on` the exit-settlement slice (#6 / ADR 0004) was waiting on.
  Independent of **#16** (hash-chaining), which excludes wall-clock `created_at`.
