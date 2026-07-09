# Domain Model — Property Management ↔ Accounts (the payments seam)

> A learning project in event-sourcing + DDD. This document is the model we
> worked out together; it is the spec to build against. Where something was
> **decided**, it says so. Where I've proposed a representation we didn't nail
> down explicitly, it's marked **(proposal)**.

---

## 1. Purpose & scope

**Thesis.** The deliverable is a **tenancy timeline** — a complete, tamper-evident
history of a tenancy (rent falling due, payments, notices, corrections) legible
enough to serve as **evidence in a tribunal (NCAT) arrears case**. This is a
learning **simulation**, not production: events are simulated and seeded, with Oban
jobs advancing time to build histories realistically. The timeline *is* the event
log's payoff — which is why the design leans on immutable, posted events and
correction-by-compensation.

We model the **seam between two bounded contexts**:

- **Property Management (PM)** — owns the tenancy, the lease terms, the
  *expected* rent, and therefore **arrears** (a management concern). This is the
  **deep** context — the whole point of the project.
- **Accounts** — owns **payment facts** (money actually received). For this
  project it is a **thin upstream edge / stub**: it emits tenancy-attributed
  payments and reversals, and nothing else is modelled.

The interesting problem is how a **payment fact born in Accounts crosses into PM
and is reconciled into arrears** — `arrears = expected − received`.

**Out of scope** (decided): disbursement to landlords, trust-account internals,
owner statements, late fees, bond/deposit, commercial (monthly) leases as a
first-class path.

**Ubiquitous language note:** the language *flips* at the seam. Accounts speaks
*payment / receipt / money*; PM speaks *arrears / weeks behind / balance*. The
translation is the anti-corruption layer.

**Simulation.** There is no real Accounts or bank. A **simulator** is the event
source: a tenant-behaviour engine (pays on time / short / misses) emits
`PaymentReceived` facts through ACL-1, and **Oban jobs advance simulated time** —
driving `RentFellDue` catch-up and the arrears trigger — so timelines accrue over
time rather than all at once.

---

## 2. Architecture of the seam

**Event sourcing, hand-rolled** (no framework — we want to feel the mechanics).

- **One physical event store** (a single append-only Postgres table). Simplest
  thing that works; in-process, no separate services. **(decided)**
- **Logical ownership is per-context.** Every event has exactly one owning
  context. A consumer **never folds another context's event directly** — it
  **translates at its ACL** into its own language first. The shared table is
  *transport*; the boundary lives in the *translation*. **(decided)**
- **Upstream/downstream is per-fact, not a global rank.** Accounts is upstream
  *for payments*; PM is upstream *for the rent schedule*. Each context both
  produces some facts and consumes others.

```
                 ┌──────────── one physical event store (append-only) ────────────┐
                 │  PaymentReceived · PaymentReversed · TenancyCommenced ·         │
                 │  RentFellDue · RentPaymentRecorded · NoticeToVacateGiven · ...  │
                 └────────────────────────────────────────────────────────────────┘
       produces payments │                                   │ produces schedule, rent-due
                    ┌─────┴──────┐   ── payments (ACL-1) ──▶  ┌─────┴──────┐
                    │  ACCOUNTS  │                            │     PM     │
                    │  (edge)    │  ◀── rent schedule (ACL-2)─│  (deep)    │
                    └─────┬──────┘                            └─────┬──────┘
       trust ledger,      │                                         │  arrears read model,
       suspense (stub)    ▼                                         ▼  14-day trigger
```

**Anti-Corruption Layer (ACL)** = a thin translation shell at a context's
boundary that stops another context's vocabulary from leaking in. *Not* an
access-control list.

---

## 3. Events (producers)

### Property Management

| Event | Payload | Notes |
|---|---|---|
| `TenancyCommenced` | `tenancy_id, property_ref, rent_amount, cycle, first_due_date, commenced_on` | Establishes the tenancy + initial rent terms |
| `RentScheduleChanged` | `tenancy_id, effective_from, new_amount, new_cycle?` | Mid-lease increase; **may be backdated** (see §6) |
| `RentFellDue` | `tenancy_id, due_date, amount, period_from, period_to` | Step tick, via lazy catch-up; **carries the amount** |
| `RentPaymentRecorded` | `tenancy_id, amount, received_on, source_payment_id` | **Output of ACL-1**; signed (reversal ⇒ negative) |
| `RentChargeAdjusted` **(proposal)** | `tenancy_id, period, delta, reason` | Compensating entry for a backdated rate change |
| `NoticeToVacateGiven` | `tenancy_id, elected_vacate_date, given_on` | **Tenant-initiated** end |
| `VacateDateAmended` | `tenancy_id, new_vacate_date, amended_on` | Moves the effective end date; **requires landlord approval** |
| `TerminationNoticeGiven` | `tenancy_id, grounds, termination_date, given_on` | **Landlord/agent-initiated**; grounds = arrears (≥14 days). Sets an effective end date |
| `TerminationNoticeVoided` | `tenancy_id, reason, voided_on` | Arrears remedied (paid **or** repayment plan) before the date ⇒ notice void, tenancy continues |
| `RepaymentPlanAgreed` **(proposal)** | `tenancy_id, terms, agreed_on` | An agreed catch-up plan; complying with it **stays** termination |
| `EarlyReleaseAgreed` | `tenancy_id, effective_date` | Landlord consents to end liability early (shortens) |
| `KeysReturned` | `tenancy_id, on_date` | Possession recovered; terminal trigger + settlement |
| `TenancySettled` **(proposal)** | `tenancy_id, refund?, overstay_charge?` | Final settlement computed at `KeysReturned` |

### Accounts (edge / stub)

| Event | Payload | Notes |
|---|---|---|
| `PaymentReceived` | `payment_id, amount, received_on, holder` | `holder = tenancy_ref | UNKNOWN` |
| `PaymentReversed` | `payment_id, reverses, amount (negative), reversed_on, reason` | Compensating entry (never edit) |

> Reallocation is **not** a distinct event: it's `PaymentReversed` on the wrong
> holder **plus** a fresh `PaymentReceived` on the right one. Correction by
> compensation, never mutation — the same discipline as PM's adjustments.

---

## 4. The `Tenancy` aggregate

**Aggregate root:** `Tenancy` (identity = `tenancy_id`).

**Consistency boundary** — folded state the aggregate holds to enforce its rules:

- lifecycle state (see state machine)
- current `RentTerms` (derived — see §7)
- `due_through` pointer (last due date booked)
- running **balance** (`Money`; negative = credit) — needed for exit refund
- set of applied `source_payment_id`s (idempotency)

**Structural finding:** tenancies are **independent** — there is **no `Property`
aggregate** above them. Re-letting can legitimately double-charge two tenancies
for the same days, so nothing needs cross-tenancy consistency.

### Lifecycle state machine

Two directions of notice both set an **effective end date**: the tenant's
**notice to vacate**, or the landlord/agent's **termination notice** (e.g. arrears).

```
                        ┌─────────────┐
        commence ──────▶│   Active    │◀── TerminationNoticeVoided ──┐
                        └──────┬──────┘        (arrears remedied)     │
            ┌──────────────────┴──────────────────┐                  │
   NoticeToVacateGiven                    TerminationNoticeGiven      │
   (tenant elects a date)                 (landlord; arrears ≥14d)    │
            └──────────────────┬──────────────────┘                  │
                               ▼                                      │
                     ┌──────────────────────┐                        │
                     │        Ending         │────────────────────────┘
                     │ (has effective end date)│
                     └───────────┬───────────┘
   VacateDateAmended (extend) / EarlyReleaseAgreed (shorten) ─ landlord-approved, adjusts the date
                                 │
             ┌───────────────────┴───────────────────┐
     keys back by end date              keys NOT back by end date
             │                                        │
             ▼                                        ▼
         (settle)                              ┌───────────┐
             │                                 │  Overstay │  daily accrual (derived ramp)
             │                                 └─────┬─────┘
             │  KeysReturned                         │  KeysReturned
             ▼                                       ▼
         ┌───────────────────────────────────────────────┐
         │        Terminal (possession recovered)         │  accrual stops; balance persists as debt
         └───────────────────────────────────────────────┘
```

> **Off-diagram (out of scope):** if a termination date lapses *unremedied* and the
> tenant hasn't left, arrears collections escalates to the **Tribunal (NCAT)** for a
> possession order. Termination *grounds* other than arrears (end of fixed term,
> breach, and the reason-based grounds from the 19 May 2025 reforms) and the
> tribunal internals are noted but **not modelled**. *No-grounds termination is
> unlawful in NSW since 19 May 2025.*

**`effective end date`** = the date the tenancy is set to end. It comes from either
a **notice to vacate** (tenant) or a **termination notice** (landlord/agent); it may
be **amended with landlord approval** — `VacateDateAmended` extends it,
`EarlyReleaseAgreed` shortens it — and it is extended by an overstay until
`KeysReturned`. It is the date the step-accrual clamp stops at.

---

## 5. Invariants

Hard invariants = the aggregate **refuses** the command. Soft guards = **warn
but allow**.

### Lifecycle
- **L1** — Notice to vacate requires a **commenced (live)** tenancy.
- **L2** — A tenancy commences **at most once**.
- **L3** — Terminal is **final**: no re-notice, no re-commence, no reopening.
- **L4** — Overstay presupposes a prior notice **and** a passed vacate date.
- **L5** — Liability can't be shortened by early departure alone; **early release
  requires landlord consent** (`EarlyReleaseAgreed`). No consent ⇒ rent runs to
  the elected vacate date (tenant liable for empty weeks).
- **L6** — The vacate date may be **amended only with landlord approval**
  (`VacateDateAmended` extends the effective end date; `EarlyReleaseAgreed`
  shortens it — both consented).
- **L7** — A **termination notice on arrears grounds** requires the tenant to be
  **≥14 days in arrears** — measured as **elapsed time**, `days_behind ≥ 14` (§7),
  *not* the dollar amount owed. The arrears projection *gates* the command.
- **L8** — Paying the arrears in full **— or entering and complying with an agreed
  repayment plan —** before the termination date **voids** the termination notice;
  the tenancy continues (a fresh notice may issue if they fall behind again). *(The
  NSW "general guarantee" against termination for remedied arrears.)*

### Accrual
- **A1** — No accrual before commencement / before the first due date.
- **A2** — `RentFellDue` (step) **never** fires past the effective end date. Past
  the vacate date, accrual continues **only** as the daily Overstay charge, and
  **only** while keys are not returned.
- **A3** — At most **one** `RentFellDue` per due date (guaranteed by the
  `due_through` pointer).
- **A4** — A rent change **may be backdated** (bitemporality: *effective* date vs
  *recorded* date). It must **not** rewrite past ticks — it emits
  `RentChargeAdjusted` (compensation). **Soft guard:** warn if no corresponding
  notice event exists, but allow override.

- **A5** — A rent increase happens **at most once per 12 months** and needs **≥60
  days written notice** (NSW, all tenancy types since 31 Oct 2024).

### Payments
- **P1** — A payment (`source_payment_id`) is applied **at most once**. (hard)
- **P2** — A reversal must reference a payment that was **actually recorded**.
  Enforced as *truth* in Accounts; PM's ACL also checks it **defensively** (a
  reversal for a payment PM never saw = a seam bug).
- **P3** — Payments are accepted **before** commencement (prepayment,
  future-dateable) — they need the tenancy to *exist*, not to be *live*.
- **P4** — Payments are accepted **after** terminal (ex-tenant paying off arrears).

> **Pattern:** accrual is **lifecycle-gated**; payment application is
> **lifecycle-agnostic**. Rent can't accrue with no live tenancy, but money can
> arrive any time.

---

## 6. Accrual model

- **Normal tenancy: step / in-advance.** The full period's rent falls due on the
  due date. One day late on a weekly cycle ⇒ owe the **whole week**, never 1/7.
- **`RentFellDue` via lazy catch-up.** The aggregate advances its own clock: on
  any interaction (payment, query), append a `RentFellDue` for each due date in
  `(due_through, min(today, effective_end_date)]`, then move `due_through`.
  Idempotent by the pointer; needs no global scheduler for correctness. An
  optional nightly sweep only keeps the read model warm.
  - *Heuristic:* **discrete change ⇒ event; linear ramp ⇒ derive.**
- **Daily rate appears only at the boundary:** the single partial period at exit,
  and the overstay ramp. Everywhere else is whole periods at exact amounts.
- **Exit settlement (decided rules; event shape is a proposal):** full periods
  stay weekly; the period containing the exit date is billed **daily to the exact
  exit day**; prepaid excess is **refunded**. Overstay extends the daily ramp to
  `KeysReturned` and **consumes any credit first** (automatic under
  balance-as-truth). Computed at `KeysReturned`.
- **What "overstay" is (NSW):** keys not returned = **no vacant possession**, so the
  tenancy *continues* accruing until `KeysReturned`. Daily charging here is a
  **practice/lease-terms convention** — kept, because the boundary partial period
  prorates to daily anyway — **not** a statutory *occupation fee* (that term means
  *goods left behind*, and daily occupation rent is actually prohibited, so we avoid
  it).
- **Backdating (bitemporality).** A legitimate rent change may be *effective* in
  the past but *recorded* now. Past `RentFellDue` ticks are frozen; the change
  emits `RentChargeAdjusted` deltas. Never mutate history.

---

## 7. Arrears

- **Balance-as-truth.** The fold is a running `Money` balance: `Σ RentFellDue −
  Σ RentPaymentRecorded` (both signed). Negative = credit.
- **Ledger presentation = double-entry (decided).** The tenant rent statement —
  the tribunal exhibit — renders as a **two-column ledger**: `RentFellDue` is the
  **debit** (charge), `RentPaymentRecorded` the **credit** (payment), running
  balance = `Σ debits − Σ credits` (the same fold). A reversal reads as a **debit**
  entry, not a "negative credit." The signed scalar above is just this ledger
  collapsed to one number. Full double-entry (balancing contra entries) is
  Accounts' native model — see §10 "Accounts → true double-entry".
- **Three reads, deliberately divergent** (all from the same balance + schedule):
  - `days_behind` — **elapsed calendar days** from the oldest unpaid due date:
    `as_of − oldest_unpaid_due_date`. **Time-based and cycle-independent** — a large
    balance does *not* accelerate it; only the clock does. **This is the read that
    gates L7** (`days_behind ≥ 14`). Clearing the oldest unpaid period (FIFO) advances
    `oldest_unpaid_due_date`, which **resets the clock** (dovetails with L8). *(decided:
    the NSW ground is time-elapsed, not amount owed — 8 days late owing "14 days' rent"
    is not defensible at tribunal.)*
  - `periods_behind` — whole unpaid periods (FIFO, oldest first); **cycle-relative**
    ("2 payments missed"). For **human communication only — never the legal gate**: a
    period count isn't comparable across weekly / fortnightly / monthly cycles (one
    unpaid *monthly* period ≠ one unpaid *weekly* one). A partial payment or small
    credit does **not** decrement it. *(Was `weeks_behind`; "weeks" baked in a weekly
    cycle.)*
  - `balance` — exact dollars; a partial **does** reduce it.
  - There is **no "paid-to date."** (Explicitly rejected as misleading — "we say
    they owe the week.")
- `periods_behind` generally needs the schedule + FIFO; it collapses to
  `ceil(balance ÷ rent)` only when rent is constant.
- **Projection (read model):** `{ tenancy_id, balance, days_behind, periods_behind,
  oldest_unpaid_due_date, as_of }`. Derived, disposable, rebuildable from the log.
  `days_behind` drives the **14-day legal arrears trigger** and *gates* the
  `TerminationNoticeGiven` command (L7) — **time elapsed, not amount owed**; the read
  model is a **precondition**, not just a report.
- **Reversals** are just negative `RentPaymentRecorded` — the fold absorbs them
  with no special case.

---

## 8. The two ACLs

### ACL-1 — PM consumes payments (Accounts → PM)
```
Accounts.PaymentReceived { holder = tenancy_ref, amount, received_on, payment_id }
    └─translate─▶ PM.RentPaymentRecorded { tenancy_id, amount, received_on, source_payment_id }
Accounts.PaymentReversed  └─translate─▶ PM.RentPaymentRecorded { …, amount: negative }
```
- **Idempotent** on `source_payment_id`.
- Fires **only for tenancy-attributed receipts**. `UNKNOWN`/suspense payments
  never cross the seam — PM's arrears is never polluted by unmatched money.
- **Defensive:** reject a reversal that references a payment PM never recorded.

### ACL-2 — Accounts consumes the schedule (PM → Accounts)
```
PM.TenancyCommenced / RentScheduleChanged
    └─translate─▶ Accounts.RentScheduleReceived { holder, amount, cycle, effective_from }
```
- Gives Accounts its own copy of the rent figure (for statements). **Out of scope
  to build deeply** — Accounts is a stub here.

---

## 9. Value objects

A value object is small, **immutable**, has **no identity**, and is equal by its
values. It's where small domain rules live, keeping the aggregate clean.

| Value object | Shape | Rules it owns |
|---|---|---|
| `Money` | `cents: integer, currency` | Arithmetic within one currency only; **never a float**; **round half-up, once, on the final amount** — never on an intermediate daily rate |
| `RentCycle` | `frequency: weekly \| fortnightly \| monthly, anchor_day` | Enumerate due dates; **month-clamping** (start 31 Jan → 28/29 Feb → 31 Mar) |
| `RentTerms` | `Money + RentCycle` | The **current** rate. **Derived state** (folded from `TenancyCommenced` + `RentScheduleChanged`), typed as a VO so "next amount" has a home. History lives in the event log, not here |
| `DayCountConvention` | `actual/actual` | Proration for the one boundary period + the overstay daily rate. Used **nowhere else** |
| `RentPeriod` | `from, to` | The span a `RentFellDue` covers |

> **Derived vs value object are orthogonal:** *derived* = how you get it (folded,
> not stored); *value object* = the shape it takes (immutable, equal-by-value).

**Scope note:** residential AU/NSW is **weekly / fortnightly**; monthly is rare
(commercial). Monthly is supported for correctness but is a lightly-trodden edge.

---

## 10. Open / parked

- Snappy name for the "keys returned late" (Overstay) situation — TBD.
- Exit-settlement event shape (`TenancySettled` / `RentChargeAdjusted`) — decided
  the *rules*, not the exact events; pin during implementation.
- Whether `RentTerms` is a standalone VO or bare aggregate fields — minor.
- **Collections beyond the notice** — Tribunal (NCAT) escalation and non-arrears
  termination grounds are **out of scope**; the notice → void → (lapse) boundary is
  captured, the tribunal internals are not.
- **Who builds what** — leaning "Claude drives", with the core learning bits
  (the event fold, the arrears projection, ACL-1) as candidates for
  hand-implementation. To be decided before coding.
- **Accounts → true double-entry (directional goal).** Longer-term aim: model
  Accounts as a real double-entry trust ledger — money *in* (receipt) and *out*
  (reversal / eventually disbursement) as balancing entries — un-stubbing it
  (§1 currently calls it a stub). Near-term stays the payment-facts edge; **build
  toward it without foreclosing**. Additive over the existing log: Accounts already
  produces the facts; double-entry is new read models + disbursement events. May
  not be reached; direction is set.
- **UNKNOWN / suspense matching (secondary/tertiary goal).** A read model + workflow
  in **Accounts** to hold and cross-reference unmatched receipts, then reallocate
  (reverse + fresh receive). Suspense is an **Accounts** entity, *never* a PM
  tenancy — routing unmatched money through a dummy PM tenancy would re-pollute the
  model ACL-1 exists to protect.

---

## 11. NSW RTA grounding (Residential Tenancies Act 2010)

Concrete figures the model rests on, verified against NSW sources. This is a
**simulation** — grounding is for realism, not legal advice.

- **Arrears termination:** >14 days behind → a non-payment termination notice giving
  **14 days** to vacate. Remedied by paying up **or** an agreed **repayment plan**
  (the "general guarantee" — L8).
- **Tenancy ends on vacant possession** (keys returned), *not* on the notice. No
  vacant possession by the date → landlord applies to **NCAT** for a termination
  order. (This is the statutory basis for `KeysReturned` = terminal.)
- **Ending — notice periods:** tenant **14 days** (fixed-term) / **21 days**
  (periodic); landlord generally **90 days** (**60** if fixed term ≤6 months),
  varying by ground.
- **No-grounds termination: unlawful since 19 May 2025** — a valid reason + evidence
  is required.
- **Rent increases:** at most **once per 12 months**, **≥60 days** written notice
  (A5).
- **"Occupation fee"** is a *goods-left-behind* term and daily occupation rent is
  **prohibited** — we don't use it; overstay is simply the tenancy continuing until
  vacant possession.

**Sources:**
[Non-payment of rent](https://www.nsw.gov.au/housing-and-construction/rules/non-payment-of-rent) ·
[Minimum notice periods](https://www.nsw.gov.au/housing-and-construction/rules/minimum-notice-periods-for-ending-a-residential-tenancy) ·
[Tenancy law has changed (2025 reforms)](https://www.tenants.org.au/resource/law-change) ·
[Dealing with goods left behind](https://www.nsw.gov.au/housing-and-construction/rules/dealing-goods-left-behind) ·
[How do I end my tenancy?](https://www.tenants.org.au/factsheet-how-do-i-end-my-tenancy)
