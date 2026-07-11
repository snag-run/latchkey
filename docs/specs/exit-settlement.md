# Spec — Tenancy exit settlement (`KeysReturned` → `TenancySettled` → Terminal)

> Source of decisions: [ADR 0004](../adr/0004-exit-settlement-events.md) and
> `docs/domain-model.md` §3/§4/§5 (L9)/§6/§7. Design issue: #6 (resolved by ADR 0004).
> Scope chosen: **full** (includes overstay). Sizing into vertical-slice tickets is a
> `to-tickets` concern, not decided here.

## Problem Statement

Today a tenancy's lifecycle stops at `Ending`. A termination notice can be given, but
there is no way to record that possession was actually recovered, no terminal state,
and no exit reckoning. So a tenancy can be *started* and *terminated* but never
financially *closed out* — the timeline can't show how a tenancy ended: the final
part-week of rent, any hold-over (overstay), and whether the tenant walked away owing
money or owed a refund. For a project whose deliverable is a tribunal-grade arrears
timeline, "how the tenancy ended and what was finally owed" is exactly the part that
matters, and it's currently missing.

## Solution

Complete the lifecycle to `Terminal` and record the exit reckoning, per ADR 0004:

- A **`KeysReturned`** command/event records possession being recovered on a date — the
  raw input fact.
- Accrual clamps to the **effective end date E**: full rent periods accrue until a full
  period no longer fits before E, then the boundary period is **pro-rated daily to E**
  (lazy, forward — never charged whole and clawed back).
- **Overstay** (keys returned after E) is booked as a single crystallised `RentFellDue`
  for the `E → keys` span at the daily rate.
- **`TenancySettled`** records the reckoning — a signed `final_balance_cents` (negative =
  refund owed to the tenant, positive = debt) — and transitions the tenancy to
  **Terminal**. It carries no money of its own; all money lives in `RentFellDue` /
  `RentPaymentRecorded`, so balance-as-truth stays literally `Σ charges − Σ payments`.
- The refund is **declared, not disbursed** — the balance simply persists in Terminal,
  the mirror of "balance persists as debt".

## User Stories

1. As a property manager, I want to record that a tenant returned the keys on a given
   date, so that the tenancy's end is captured as a fact in the timeline.
2. As a property manager, I want a tenancy that has reached its effective end date and
   had keys returned to become **Terminal**, so that it is unambiguously closed.
3. As a property manager, I want the final part-week of rent charged only for the days
   actually within the tenancy (pro-rated to the effective end date), so that the tenant
   is not billed a whole week for a few days.
4. As a property manager, I want full rent periods to keep accruing normally right up
   until a full period no longer fits before the end date, so that only the true
   boundary period is ever pro-rated.
5. As a property manager, I want a tenant who holds over past the end date (keys not
   returned) to keep accruing rent **daily** until keys come back, so that the hold-over
   is charged, consistent with NSW (no vacant possession = tenancy continues).
6. As a property manager, I want the overstay to be booked as one charge computed when
   keys are returned, so that the log isn't cluttered with a daily event per hold-over
   day.
7. As a property manager, I want a tenant who overpaid (prepaid rent beyond what the
   pro-rated exit actually charged) to have that excess show as a **refund owed**, so
   that the timeline is honest about money we hold that belongs to them.
8. As a property manager, I want any credit the tenant is holding to be **consumed first**
   against overstay before a refund is computed, so that we don't refund money that an
   overstay charge should absorb.
9. As a property manager, I want the tenancy's final reckoning recorded as a single
   settlement fact showing the final balance, so that the exhibit has a clear "this is
   how it ended" line.
10. As a property manager, I want a tenant who left owing rent to have that **debt
    persist** on the terminal tenancy, so that the arrears remain visible and provable
    after the tenancy closed.
11. As an ex-tenant, I want to still be able to pay down arrears after the tenancy is
    terminal, so that a debt can be cleared post-exit (P4).
12. As a tribunal exhibit reader, I want each exit charge (boundary pro-ration, overstay)
    to appear as its own dated ledger line with its period, so that the final reckoning
    is auditable rather than a single opaque number.
13. As the developer, I want the effective end date folded into aggregate state from the
    termination notice, so that accrual can clamp to it and settlement can compute
    against it.
14. As the developer, I want `RentFellDue` to carry `period_from`/`period_to`, so that
    the boundary and overstay charges can express the exact span they cover.
15. As the developer, I want every new event to carry the bitemporal envelope
    (`effective_date`, `recorded_on`), so that the timeline can present effective-vs-
    recorded dates uniformly.
16. As the developer, I want `KeysReturned` refused unless the tenancy has an effective
    end date (is `Ending`/overstaying), so that keys can't be "returned" on a live
    tenancy that was never ending (L9).
17. As the developer, I want `KeysReturned` to be terminal and to fire at most once, so
    that a settled tenancy cannot be re-settled or reopened (L3, L9).
18. As the developer, I want the return-keys decision to first catch rent up to the end
    date, then add overstay if applicable, then emit `KeysReturned` and `TenancySettled`,
    so that the settlement is computed over a fully-booked ledger.
19. As the developer, I want `final_balance_cents` computed from the fold at settlement
    time and recorded on `TenancySettled`, so that the exhibit has the exact closing
    figure without recomputation.
20. As the developer, I want the read model to reflect the tenancy as terminal with its
    final balance, so that the closed state is observable through the supported query
    API.
21. As the developer, I want the exit path to be exercised end-to-end through the
    existing command→read-model seam, so that the whole loop (dispatch → project →
    query) is proven, not just the aggregate internals.
22. As the developer, I want the aggregate's exit decisions and fold to be unit-testable
    with no infrastructure, so that the pro-ration, overstay, and refund maths are
    covered fast and in isolation.

## Implementation Decisions

- **Two events (ADR 0004):** `KeysReturned` (input fact) and `TenancySettled` (reckoning
  + terminal transition). `TenancySettled` carries **no money of its own**.
- **Lifecycle:** extend the derived-state machine `pending → active → ending → terminal`.
  **Overstay is derived**, not a stored status — it is the region where `as_of >
  effective_end_date` and keys are not yet returned. No `AshStateMachine`; state derives
  from the fold (ADR 0001/0003).
- **Effective end date in state:** the aggregate folds the effective end date E from the
  termination notice (today the notice's date is dropped by the fold — this slice folds
  it in). E is the clamp for step accrual and the reference for overstay.
- **Catch-up becomes end-date-aware:** step `RentFellDue`s fire for whole periods until a
  full period no longer fits before E; the boundary period (the one containing E) is
  emitted **pro-rated daily to E**. No step charge fires past E — hold-over is handled by
  overstay at keys-return.
- **Boundary pro-ration:** charge `= round_half_up(period_rent × days_in_period_to_E ÷
  period_length)`, using `DayCountConvention` actual/actual and `Money`'s round-half-up-
  once-on-the-final-amount rule (§9). Emitted as a `RentFellDue` whose `period_to` is E.
- **Overstay charge:** if the keys-return date is after E, emit a **single** `RentFellDue`
  spanning `E → keys` at the daily rate (`period_from = E`, `period_to = keys date`),
  computed at keys-return. Linear ramp ⇒ one derived figure, not per-day events.
- **`RentFellDue` gains `period_from`/`period_to`** (already listed in domain-model §3;
  the struct currently lacks them).
- **Return-keys decision composition:** catch rent up to `min(keys, E)` → append overstay
  `RentFellDue` if `keys > E` → append `KeysReturned` → append `TenancySettled`. Mirrors
  the existing `decide_termination` pattern (`catch_up ++ notice`).
- **`final_balance_cents`:** computed from the fold (`Σ RentFellDue − Σ RentPaymentRecorded`)
  after the boundary/overstay charges are folded, recorded (signed) on `TenancySettled`.
  Negative = refund owed to tenant; positive = debt. "Consumes credit first" and "prepaid
  excess refunded" both fall out of this with no special handling.
- **Refund is declared, not disbursed:** no refund/payment-out event in PM. The terminal
  balance persists. A future Accounts un-stub would cross ACL-1 as a negative
  `RentPaymentRecorded` to zero it — additive, out of scope here.
- **Bitemporal envelope:** `KeysReturned` and `TenancySettled` (and the exit `RentFellDue`s)
  carry `effective_date` + `recorded_on`. `recorded_on` is domain (simulated) time, not
  the EventStore's wall-clock `created_at`.
- **Invariant L9:** `KeysReturned` requires an effective end date (tenancy `Ending`/
  overstaying), reaches Terminal, fires at most once; a second is refused, as is
  keys-return on an `active`/`pending` tenancy. L3 keeps Terminal final.
- **Read model:** the projection reflects the tenancy as **terminal** with its final
  balance, projected from `TenancySettled`. Payments after terminal remain accepted (P4).
- **Aggregate stays framework-free:** all new decisions/folds live in the pure
  `Tenancy` decide/evolve core; the Commanded shell only adapts events.

## Testing Decisions

- **What a good test asserts here:** behaviour through public APIs only — dispatch
  commands, assert on the projected read model (and, for the fast maths, on the pure
  aggregate's decide/evolve output). Never assert on EventStore tables, the aggregate
  struct internals, or projector internals. Tests describe outcomes ("returning keys on
  the end date closes the tenancy with the final week pro-rated", "holding over a week
  adds one overstay charge", "a prepaid tenant ends with a refund owed that persists").
- **Modules under test:** the pure `Tenancy` decide/evolve core (unit, no infra) for the
  pro-ration / overstay / refund / L9 logic; and the **command→read-model integration
  seam** (real Commanded app + Postgres EventStore + async projector) for the end-to-end
  loop.
- **Prior art:** the aggregate unit tests and the integration test established by #20 /
  ADR 0003 (dispatch a command, assert the projected read model; EventStore reset between
  runs). This slice reuses both — no new seam.
- **Key cases:** on-time exit (boundary pro-rated, terminal, correct final balance);
  overstay (single overstay charge, correct span, credit consumed first); prepaid exit
  (negative `final_balance_cents`, persists); debt exit (positive balance persists,
  post-terminal payment still applies); L9 refusals (keys on a live tenancy; second
  keys-return).

## Out of Scope

- **Tenant-initiated ending** (`NoticeToVacateGiven`) and the amend/shorten events
  (`VacateDateAmended`, `EarlyReleaseAgreed`). This slice reaches Terminal via the
  existing arrears-termination path only.
- **Backdated rate changes / reverse+repost / `RentChargeAdjusted`** — deferred to the
  rent-increase slice (ADR 0004).
- **The actual refund disbursement** — requires the Accounts un-stub (§10 directional
  goal).
- **Non-weekly cycles** — weekly only, matching the current slice; fortnightly/monthly
  arrive with the accrual-cycle work.
- **The simulated clock (#4)** — commands take explicit dates; no Oban time advance here.
- **The timeline read model / UI (#5)** and **hash-chaining (#16)** — this slice only
  produces the events those consume.

## Further Notes

- Closes out design issue **#6** (its deliverable was ADR 0004; this is the build).
- Feeds **#5** (the bitemporal envelope + exit events are what the timeline renders) and
  is fed by **#4** eventually (which will supply `recorded_on` from the simulated clock),
  but depends on neither to ship.
- The one residual backdate-like case — `EarlyReleaseAgreed` shortening E into already-
  charged territory — is explicitly deferred with the early-release slice (ADR 0004).
