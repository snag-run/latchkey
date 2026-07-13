# 0009 — Payment cycles: weekly, fortnightly, monthly

Status: **accepted** — makes the `cycle` field of
[`0005`](0005-simulation-and-time-model.md) (carried on `TenancyCommenced` since the
tracer-bullet slice) *meaningful* for the first time. Extends the demo-scale board of
[`0007`](0007-seed-catalogue-at-demo-scale.md) so tenancies pay on genuinely
different cadences, not just staggered due dates.

## Context

`TenancyCommenced` has always carried a `cycle`, but it is **inert**: `decide_commence`
rejects anything but `:weekly` (`:unsupported_cycle`), and every accrual path is
hardwired to a 7-day period — `Date.add(_, 7)` for the next due date, and a fixed
`÷ 7` denominator in the exit boundary (#31) and overstay (#32) pro-ration. The seed
catalogue is weekly throughout (`@week = 7`, `Schedule.weekly/4`).

The board already shows a spread of *due dates* (each tenancy commences on a different
backdated day), but every tenancy pays **weekly**. Real tenancies don't: weekly,
fortnightly, and calendar-monthly are all common. A demo board whose purpose is to make
the arrears/exit machinery legible should show that variety, and the deliverable is a
tribunal-grade evidence timeline — a fake cadence would be the one thing an assessor
could poke at.

Fortnightly is a trivial generalisation (a 14-day period). **Monthly is the real
decision**, because calendar months are 28–31 days, so "the next due date" and "the
daily rate for a partial period" both stop being fixed arithmetic.

## Decisions

### 1. Three cadences; the catalogue seeds a 60 / 30 / 10 mix

Support `:weekly` (7-day period), `:fortnightly` (14-day period), and `:monthly`
(calendar month). The generated catalogue draws them **60 % weekly / 30 % fortnightly /
10 % monthly**; the three hand-authored *featured* headline scenarios stay weekly (they
are the legible teaching cases).

**Assignment rule (deterministic, so the board stays a pure function of `today` —
ADR 0005 decision 8 reproducibility):**

- The three featured scenarios are **excluded** from the split — always weekly, and
  they are not part of the denominator.
- The split applies to each **generated category independently** (`healthy`, `arrears`,
  `under_notice`, `exited`, `relet`), keyed on that category's local `idx` via
  `rem(idx, 10)`: `0–5 → :weekly`, `6–8 → :fortnightly`, `9 → :monthly`.
- A category whose size is not a multiple of 10 therefore fills **weekly-first,
  fortnightly-next** in its trailing partial block — the remainder rule is just the
  modulo, with no rounding or tie-breaking. Small categories skew weekly as a
  consequence (`exited`, size 3, lands all-weekly), which is acceptable.

`rent_amount_cents` is the **whole-period rent for that cadence** — a monthly tenancy
carries a monthly amount, a weekly one a weekly amount. We never convert between them
(the `weekly ÷ 7 × 365 ÷ 12` annualisation agents use to *quote* a monthly figure is
not our concern; we pick the periodic rent directly).

### 2. Monthly due dates advance **from the commencement anchor**, clamped to month-end

Rent is due on the same day-of-month as `first_due_date`. The *n*th due date is computed
**from the original anchor** (`Date.shift(first_due_date, month: n)`), not by iterating a
month off the previous due date. The two differ only after a short month, and the
difference is the whole point:

- **From anchor (chosen):** commence Jan 31 → Feb 28 → **Mar 31** → Apr 30 → **May 31**.
  The 31st "comes back" whenever the month has it — which is how a "due on the 31st"
  tenancy actually reads.
- From previous due (rejected): Jan 31 → Feb 28 → **Mar 28** → Apr 28 … once it clamps
  it is stuck at 28 forever, silently drifting the anchor.

`Date.shift/2` (Elixir 1.17) clamps a day that a month lacks to that month's last day
(Jan 31 `+1 month` → Feb 28/29), which we accept as-is. Weekly and fortnightly keep the
fixed `+7` / `+14` advance — no anchor arithmetic needed.

### 3. Pro-ration is **actual/actual** over the real period length

The exit boundary charge (#31) and overstay charge (#32) pro-rate a partial period as

    period_rent × days_in_span ÷ days_in_that_period

where `days_in_that_period = Date.diff(period_end, period_start)` — the **actual** length
of the period the span falls in. This is one denominator for all three cadences: 7 for
weekly, 14 for fortnightly, and the real 28–31 for monthly. It replaces the hardwired
`÷ 7`.

This is the established real-world convention, not a modelling shortcut: an Australian
monthly tenancy pro-rates a partial month by dividing the fixed monthly rent by the
**actual days in that specific month** (e.g. a partial August ÷ 31, a partial February
÷ 28), so a day in February genuinely costs more than a day in March for the same
monthly rent. The half-up-once rounding rule (Money §9) is unchanged — only the
denominator generalises.

**Overstay across a period/month boundary.** The overstay charge (#32) is a *single*
`RentFellDue` over `[E, V)` (exit-settlement spec), so with a monthly cadence a span
that crosses a month boundary (E in a 28-day February, V in a 31-day March) needs one
unambiguous daily rate. We fix the denominator to **the last scheduled period** — the
period E falls in, which for a **boundary-aligned** E (E exactly on a due date) is the
period *ending* at E, i.e. `[due(m-1), due(m))`, **not** the post-exit period *starting*
at E — and apply that flat daily rate across the whole `[E, V)` span. The
overstay is a hold-over penalty reckoned at keys-return off the last period's rate, not
a continuation of the schedule into fresh periods, so it stays one derived figure and
never re-pro-rates per-month. Piecewise splitting of a cross-boundary overstay by each
month's actual days is **explicitly deferred** — no evidence the demo needs it, and the
`[E, V)`-on-one-event model does not foreclose it.

## Consequences

- **Write model:** `decide_commence` accepts `:fortnightly` and `:monthly`;
  `decode_cycle` learns them. The accrual walk (`catch_up_events`) advances by the
  cadence's period rather than a literal `+7`, and the shared pro-ration helper divides
  by the actual period length. `cycle` stops being inert.
- **Simulation:** `Schedule` gains fortnightly/monthly period builders alongside
  `weekly/4`; the `Scenario`/`Catalogue` carry a per-tenancy `cycle` and the 60/30/10
  split; `Projection.derive/2` folds the chosen cadence so `:expected` stays truthful.
  `Timeline` reads the period span from the event rather than assuming 7.
- **No PII / identity impact** — orthogonal to the [`0008`](0008-property-tenant-identity-and-property-balance.md)
  `property_ref` work. Both add to `TenancyCommenced`; whichever lands second rebases a
  one-line field addition.
- **`domain-model.md`** §6/§7 (accrual) gains the non-weekly cadences; the "one whole
  period per due date" invariant holds, only the period length varies.
- **Deferred:** other cadences (e.g. 4-weekly, quarterly) and mid-tenancy cadence
  changes are out of scope — no evidence the demo needs them, and the `cycle`-on-the-event
  model does not foreclose them.
