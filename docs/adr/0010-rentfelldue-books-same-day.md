# 0010 — `RentFellDue` books same-day; `recorded_on > occurred_on` means "imported"

Status: **accepted** — resolves issue #118. **Supersedes
[ADR 0005](0005-simulation-and-time-model.md) decision 4** (the "lazy accrual — accrual
ticks lag, `recorded ≥ effective`" framing). ADR 0005 decisions 3, 5, 6, 8, 9 stand.

## Context

ADR 0005 decision 4 framed a swept `RentFellDue` as lagging its due date: the sweep
running on 20 Mar books the charge that fell due on 5 Mar, so `occurred_on = 5 Mar`,
`recorded_on = 20 Mar` → `recorded_on ≥ occurred_on` ("lazy accrual, categorically not
backdating"). That divergence was an artifact of stamping every tick with the sweep's
**run-date** (`Clock.today()`, threaded from the command).

But a `RentFellDue` is **auto-calculated** — the system knows the whole rent schedule
the moment a tenancy commences. There is no human deciding when to "book" a period; it
falls due on its own date by arithmetic. Stamping the sweep's run-date recorded a
booking lag that has no domain meaning: a tick swept in late and a tick swept in on time
describe the *same* fact, and the inspector's `occurred ≠ recorded` divergence flag lit
up for both — noise, not signal.

There **is** one case where a `RentFellDue`'s `recorded_on` legitimately post-dates its
`occurred_on`: a tenancy **transferred/imported** from another PM system, whose history
is *rebuilt* after the fact (issue #117). There, the rebuild date is real and later than
the historical due dates.

## Decision

**A system-managed `RentFellDue` books on its own due date: `recorded_on == occurred_on`,
no bitemporal divergence.** The three aggregate producers
(`whole_period_charge`, `boundary_charge`, `overstay_events` in
`Latchkey.PropertyManagement.Tenancy`) self-stamp `recorded_on = occurred_on` when the
threaded `recorded_on` is `nil`. Every organic decision
(`decide_catch_up`, `decide_payment`, `decide_termination`, `decide_return_keys`) passes
`nil` for the accrual ticks — swept catch-up, payment self-catch-up, notice-time
catch-up, and exit reckoning all book same-day. This uniformly kills the divergence for
non-imported tenancies.

**The threaded `recorded_on` parameter is kept, not removed.** A non-`nil` value is
stamped onto every tick and is the **sole** legitimate `recorded_on > occurred_on` case:
an imported/transferred tenancy whose history is rebuilt (issue #117) threads the real
rebuild date through `catch_up_events/3` / `overstay_events/4`. The plumbing is the
extension point that path needs.

**The co-emitted lifecycle events keep booking at `Clock.today()`.** A payment, notice,
commence, keys-return, or settlement genuinely *happens when recorded*, so those events
still carry the command's `recorded_on` (Sydney wall-clock via `booked_on/1`, ADR 0005
decision 2). Only the auto-calculated `RentFellDue` ticks self-stamp same-day.

**Consequence — a sharper flag.** The inspector's `occurred ≠ recorded` divergence badge
on a `RentFellDue` now means exactly one thing: **this tenancy was imported** (#117). It
is no longer diluted by sweep-lag noise.

## What stands from ADR 0005

- **Decision 3** (`recorded_on` ≠ `created_at` for seeded history) **holds unchanged.** A
  seeded backhistory `RentFellDue` books `recorded_on = occurred_on = <its historical due
  date>`, still distinct from `created_at = <the afternoon the seed script ran>`. Seeded
  history still looks accrued-over-time (its dates are historical), not all-at-once-today
  (which is `created_at`). Only the *intra-envelope* lag between `occurred_on` and
  `recorded_on` is retired for accrual ticks.
- **Decisions 5, 6** (the sweep as visibility backstop; `days_behind` computed on read)
  are untouched — the sweep still books the periods owed; it just stamps each on its own
  due date.
- **Decision 9** (seeding replays the live engine over historical dates) holds and is in
  fact *reinforced*: seed and live now agree on `RentFellDue` stamping with no
  seeder-specific `recorded_on` assignment for accrual.

Notices keep their own envelope direction (occurrence = served date, `recorded_on` =
booking date); this ADR scopes only the auto-calculated `RentFellDue`.

## Consequences

- `Latchkey.PropertyManagement.Tenancy` — producers default `recorded_on` to
  `occurred_on`; organic decisions thread `nil`.
- Docstrings/comments retired the "lazy accrual / `recorded ≥ occurred`" framing across
  `tenancy.ex`, `sweep.ex`, `catch_up.ex`, `rent_fell_due.ex`, and the inspector
  event-log pane.
- Tests: the organic-accrual assertions now pin `recorded_on == occurred_on`; the two
  read-side divergence tests (timeline sort, inspector flag) are re-labelled "imported"
  — they still exercise the render capability, which #117 will feed for real.
- `CONTEXT.md` "three time axes" updated: `recorded_on` coincides with `occurred_on` for
  system-managed accrual and lags only for imports.

## Follow-up

- **#117** — the imported-tenancy seed scenario reintroduces `recorded_on > occurred_on`
  legitimately by threading a rebuild date through the kept parameter. Depends on this.
