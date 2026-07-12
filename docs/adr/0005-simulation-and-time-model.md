# 0005 — Simulation & time model: wall-clock time, simulated tenant, human agent

Status: **accepted** — resolves issue #4. Decides how simulated time works so
tenancy histories build up realistically instead of all at once, and what is
simulated vs. driven by the human user. Supersedes part of
[ADR 0004](0004-exit-settlement-events.md) §5 (`recorded_on` reframed, not retired).
**Envelope direction (decision 4) superseded by
[ADR 0006](0006-tenancy-timeline-read-model.md)** — `effective_date` is renamed
`occurred_on` (occurrence, uniform) and kick-in dates are payload. **`recorded_on`
(decision 3) is retained unchanged** — no `recorded_on` rename is implied. This
body is left unchanged; only this Status pointer is added.

## Context

`domain-model.md` §1 says the deliverable is a **tenancy timeline** legible as
tribunal evidence, built by "Oban jobs advancing time" over a **simulation** — there
is no real Accounts or bank. What was undecided: where "now" comes from, what Oban
actually does, what a tenant "behaviour" is, and how histories are seeded. #4's
blocker (#3, ES foundation — [ADR 0003](0003-es-foundation-bakeoff.md)) is closed.

Grilling surfaced that the biggest decision isn't the clock — it's **what is
simulated at all**. The rest follows from that and from keeping "now" an *input* to
`decide` (fold-as-truth, ADR 0001/0003) rather than aggregate state. The `Tenancy`
aggregate already takes explicit dates (`as_of`, `received_on`, `given_on`); there is
no clock in the domain, and this ADR keeps it that way.

## Decisions

### 1. Simulated tenant, human agent — the scope line

The simulation drives exactly **two** things: **time** (the sweep) and **the tenant**
(pays / short / late / misses). **Everything on the agent/agency side is the human
end-user's decision** — issue the termination notice, void it, agree a repayment
plan. There is **no landlord-agent behaviour engine**. The app *surfaces* an
affordance (arrears-termination available) and the user chooses whether and *when*
to act — day 14, week 3, or never. This is the interactive boundary of the whole
deliverable: you walk into a board of tenancies in interesting states and play the
agent; the timeline records your decisions as evidence.

- *Sharpens §1:* "Oban jobs… driving **the arrears trigger**" now reads
  **eligibility *surfaces*, not an action fires**. The trigger lights a button; the
  user pulls it.

### 2. Live time is wall-clock, 1:1 — no stored clock, no speed knob

"Now" for the live path is wall-clock time, read in **`Australia/Sydney`**. There is
**no** stored `simulation_clock` and **no** simulation-speed multiplier. Two
capabilities that a speed knob would otherwise provide are already covered elsewhere,
so it would be pure duplication:

- **Backhistory** is manufactured by **seeding backdated events** (decision 9), not by
  fast-forwarding a live clock.
- **As-of views** ("show the timeline at day 30") are a **read-side replay** — fold
  events with `recorded_on ≤ T` — which event-sourcing gives for free.

- *Rejected — stored sim-date singleton:* mutable clock state outside the log to
  advance/park/rewind independently of wall time. More machinery than the sim needs.
- *Rejected — wall-clock-derived with a speed factor:* chains sim progress to real
  elapsed time (awkward to pause, awkward to fast-forward a seed run) and duplicates
  seeding + replay.

**Timezone is correctness, not cosmetics.** `days_behind` is calendar-day arithmetic
and the L7 gate is exact and inclusive (s88: "not less than 14 days"). Sydney is
UTC+10/+11, so UTC "today" lags Sydney "today" for ~10 h/day — a payment booked
Sydney-morning could land on the wrong calendar day and throw `days_behind` off by
one **right at the 14-day boundary**. So "now" is a **Sydney** date and `recorded_on`
is a Sydney date. Named-zone, DST-aware lookups need a timezone database (Elixir ships
UTC-only) → add the lightweight pure-Elixir `tz` dep (`config :elixir,
:time_zone_database, Tz.TimeZoneDatabase`). This is the date/time exception CLAUDE.md's
"no new deps" rule explicitly allows.

**`Clock` is the single edge read-site — not a service domain code depends on.**
Domain code stays pure, threading `as_of :: Date.t()` (the aggregate already does).
A one-function `Latchkey.Clock.today/0` returns the Sydney date and is called in
exactly one place per entrypoint — **the Oban sweep job and the seed script**. It is
**not** injected into `decide`/the behaviour engine (those take `as_of`); it only
gives the edge its "now." This keeps the pure test seam pure, puts the timezone in one
place, and makes the wall-clock read stubbable. It does **not** reintroduce a stored
sim-clock — it's a stateless read of wall-time.

Consequence: the interactive *live* loop is genuinely slow (you wait real days for
arrears to build), so the interesting scenarios come **pre-seeded** and live is the
slow drip. This shapes seeding (decision 9), not the clock.

### 3. `recorded_on` kept; ADR 0004 §5 amended, not retired

ADR 0004 §5 pinned `recorded_on` as "**simulated** time, deliberately distinct from
the store's wall-clock `created_at`." Under a wall-clock live clock, that distinction
*collapses for live events* (`recorded_on == created_at`). The field still earns its
keep, so the definition is **reframed**, not dropped:

> `recorded_on` = **the date the fact was booked in the simulation**: **wall-clock**
> for live events (coincides with `created_at`, harmlessly), **seeder-assigned** for
> history (diverges from `created_at` — a backhistory `RentFellDue` books
> `recorded_on = <a day in March>` while `created_at = <the afternoon the seed script
> ran>`).

That divergence *is* what makes seeded history look accrued-over-time rather than
all-at-once-today — the entire point of the #5 timeline projection (render effective
vs. recorded). `created_at` stays real wall-clock time and stays out of #16's hash
preimage.

- *Rejected — drop `recorded_on`, collapse the envelope to `effective_date` +
  `created_at`:* simpler, but loses booking-lag (a payment *for* the 1st not *booked*
  until the 15th) — the messy-ledger realism that makes an exhibit look real — and
  leaves seeded history with no story-time distinct from real insert-time.

### 4. Envelope direction is **per-event-kind**; lazy accrual is not backdating

ADR 0004 called forward-dating (`effective ≥ recorded`) "the normal case," but that
was about **notices**. Under lazy accrual the direction **inverts** for accrual ticks:
the sweep running on day 20 books the `RentFellDue` that *fell due* on day 5, so
`effective_date (due_date) = day 5` and `recorded_on = day 20` → **`recorded ≥
effective`**. This is **lazy accrual — categorically not the "backdating" A4/§6
defer**, which *disturbs already-posted events*; catch-up disturbs nothing, it's the
*first* booking of that period.

So envelope direction is per-event-kind: **notices forward-date** (`effective ≥
recorded`); **accrual ticks lag** (`recorded ≥ effective`); **true backdating**
(`effective < recorded` *and* corrects posted events) remains rare and deferred.

### 5. The sweep — mechanical daily catch-up, load-bearing for *visibility*

A daily Oban cron, per live tenancy, dispatches `CatchUp{as_of: today}`, booking the
`RentFellDue`s owed through `min(today, effective_end_date)` and advancing
`due_through`. Idempotent by the pointer, so double-runs are harmless — and the
pointer's idempotency is only *safe under concurrency* because **Commanded serializes
commands per aggregate instance**: two overlapping sweeps for the same tenancy route to
the same aggregate process and run in sequence, so the second sees the advanced
`due_through` and emits nothing. (Were dispatch ever parallelised per stream, this
would instead need optimistic-concurrency retry on the expected-version conflict.) **It
never issues notices** (decision 1).

Its essential job is **making silence visible, not warming a cache.** `decide_payment`
already calls `catch_up_events` before recording a payment, so a **paying tenant
catches *itself* up** — every payment command books the periods owed since last time.
The only tenancies that never receive a command are the ones who **stopped paying** —
and those are exactly the ones you need to see in arrears. An unbooked due date reads
as `oldest_unpaid_due_date = nil` (tenant looks paid-up); the sweep is the **backstop
for non-payers** that reveals their arrears. That is §6's "the nightly sweep is
load-bearing, not cache-warming" made concrete.

Fan-out shape (single cron + `Task.async_stream` back-pressure vs. one child Oban job
per tenancy) is an **implementation detail for the build ticket** — not load-bearing.
Lean toward per-tenancy child jobs for retry isolation and per-tenancy observability.

### 6. `days_behind` is computed on read, as-of today

Store only `oldest_unpaid_due_date` (event-driven); derive `days_behind =
Clock.today() − oldest_unpaid` **at query time** (Sydney, decision 2 — *not*
`Date.utc_today()`, whose boundary drift is the whole reason decision 2 exists).
`oldest_unpaid` *doesn't move* as
a tenant keeps missing (new misses grow the *balance*, not the pointer), so
`days_behind` climbs **purely from the clock, with no new event** — an idle arrears
tenant's counter is always correct on read, and the sweep is freed from re-stamping a
stored number daily (its only job stays *visibility*, decision 5).

The eligibility affordance (decision 1) reads this and is therefore **never
stale-by-clock**. L7 stays a **write-side invariant**: on the user's click,
`decide_termination` re-computes `days_behind` from the aggregate fold and refuses if
the tenant paid in the meantime — a stale "eligible" button can never wrongly
authorise a termination (§7 already forbids the projection gating a command).

- *Fixes a live bug:* `ArrearsProjector` currently sets `as_of = due_through ||
  first_due_date`, measuring `days_behind` as-of the **last booked due date** instead
  of *now* — it freezes an idle tenancy's counter. Retire that; compute on read.
- *Rejected — store `days_behind` and re-stamp every live tenancy daily:* matches §7's
  projection shape literally, but makes the sweep touch every tenancy daily and the
  number is stale between runs.

### 7. Simulated payments flow through the full ACL-1 seam

The behaviour engine appends a `PaymentReceived` **fact to the Accounts stream**;
**ACL-1** — a checkpointed, replay-safe policy idempotent on `source_payment_id` (§8)
— translates it and dispatches `RecordPayment` to the PM aggregate. The engine is
**Accounts' sole producer** (`PaymentReceived` / `PaymentReversed`, the two §3 edge
events); the Accounts stub's data *is* the simulator's output.

- *Rejected — shortcut straight to `RecordPayment`:* would simulate everything
  *except* the one seam the project exists to study (§1: "how a payment fact born in
  Accounts crosses into PM"). Non-negotiable.

This names **Accounts-stub + ACL-1** as build scope implied by #4 — neither exists in
code yet (only the PM `Tenancy` aggregate + `Arrears` read model do). `/to-tickets`
slices them as their own tickets downstream of this ADR.

### 8. Behaviour = deterministic archetypes, three tiers of irregularity

A behaviour profile is a function `(profile, schedule, date) → maybe PaymentReceived`
— and **the same function runs over past dates at seed time and over `today` live**
(one rule, two clocks; the payoff of "now" being an injected input). Profiles are
**deterministic archetypes** — a small named set (`reliable`, `chronically-late(+N)`,
`deteriorating`, `sporadic`) — expressed as **parameterised rules + optional explicit
per-period overrides + optional *seeded* lateness jitter**. Reproducible by
construction, so a demo reliably shows the interesting case and tests are stable.

"Late then catches up" is resolved by separating **scripted** from **reactive**:

1. **Stateless jitter** — `lateness = base + seeded_random(0..N)`, full amount. In.
2. **Scripted irregularity** — a hand-authored per-period list (`[on-time, on-time,
   miss, pay-double, …]`); models catch-up by **authoring** it, not simulating the
   tenant's reasoning. In.
3. **Reactive catch-up** — the tenant *reads its own arrears state* and decides to pay
   a lump. A **feedback loop**, the **same category** as "complies with the repayment
   plan." **Deferred** (§10).

- *Rejected — stochastic profiles* ("pays on time 80%"): lifelike variance, but fights
  the reproducibility and guaranteed-timeline demoability a tribunal-evidence learning
  sim needs. Seeded jitter buys the variance without the cost.

### 9. Seeding replays the live engine over historical dates

Backhistory is produced by calling the **same decision functions** (behaviour engine +
`catch_up`) parameterised with **historical dates** instead of `Date.utc_today()`,
iterating each tenancy's **due/payment schedule** in the window (a handful of steps,
not 90 calendar days). Seeded history is therefore **identical to what live would have
produced in decision path and ledger outcomes** (the same events, amounts, and
`effective_date`s) — modulo the deliberately-divergent `recorded_on` (seeder-assigned,
decision 3) and the store's `created_at`. No synthetic-looking artifacts in the
exhibit, and "seed = the live loop run over past dates" is literally true. This is
**not** the rejected speed knob
(decision 2): it's a write-side history generator iterating a schedule; the live
wall-clock is untouched.

A seed is a **named scenario catalogue**, not a random population: each tenancy is an
archetype + backdated commence date + optional **planted agent events**, **engineered
to sit at a chosen state *today*** — e.g. `paid-up`, `20-days-behind-no-notice-yet`
(the money demo case), `notice-issued-then-tenant-paid` (a void candidate for the user
to resolve). That is what makes the app **interactive on load**. Reproducible via
seeded RNG.

- *Rejected — bulk-append analytically-computed events:* faster to write once, but a
  **second code path** that can silently drift from live behaviour, so demo history and
  live history would obey different rules.

## Consequences

- **Amend [ADR 0004](0004-exit-settlement-events.md) §5** and `domain-model.md` §3
  envelope note: `recorded_on` reframed (decision 3); envelope direction is
  per-event-kind (decision 4).
- **Sharpen `domain-model.md`** §1 (arrears trigger = eligibility surfaces; simulated
  tenant / human agent) and §6 (sweep = visibility backstop for non-payers).
- **Fix `ArrearsProjector`**: store `oldest_unpaid_due_date`, compute `days_behind` on
  read as-of today; drop `as_of = due_through` (decision 6).
- **Add `docs/adr/` §10 items**: reactive/self-aware tenant behaviour deferred, grouped
  with repayment-plan compliance (same feedback loop).
- **Build scope implied for `/to-tickets`** (each its own ticket, sized downstream):
  - `tz` dep + `Latchkey.Clock.today/0` (Sydney date; the single edge read-site).
  - Oban added to deps + config (not currently present); daily sweep cron job.
  - Accounts stub context + `PaymentReceived` / `PaymentReversed` events.
  - ACL-1 checkpointed policy (Accounts → PM), idempotent on `source_payment_id`.
  - Tenant behaviour-engine archetypes (parameterised rules + overrides + seeded
    jitter).
  - Seed scenario catalogue (replays the engine over historical dates; reproducible).
  - Bitemporal envelope (`effective_date` / `recorded_on`) retrofit across events — the
    cross-cutting retrofit ADR 0004 left un-ticketed, now unblocked.

## Deferred

- **Reactive / self-aware tenant behaviour** (tier 3, decision 8) — the tenant reacting
  to its own arrears or to an agent's repayment plan. A feedback loop; grouped with the
  §10 repayment-plan-compliance question.
- **Fan-out shape** of the sweep (`Task.async_stream` vs. per-tenancy child jobs,
  decision 5) — an implementation call for the build ticket.
