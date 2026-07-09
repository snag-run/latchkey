# Domain Model — Property Management ↔ Accounts (the payments seam)

> A learning project in event-sourcing + DDD. This document is the model we
> worked out together; it is the spec to build against. Where something was
> **decided**, it says so. Where I've proposed a representation we didn't nail
> down explicitly, it's marked **(proposal)**.

---

## 1. Purpose & scope

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
| `NoticeToVacateGiven` | `tenancy_id, elected_vacate_date, given_on` | |
| `EarlyReleaseAgreed` | `tenancy_id, effective_date` | Landlord consents to end liability early |
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

```
                 ┌─────────────┐
   commence ────▶│   Active    │
                 └──────┬──────┘
                        │ NoticeToVacateGiven(elected_vacate_date)
                        ▼
                 ┌─────────────┐   EarlyReleaseAgreed(effective_date)
                 │   Notice    │─────────────┐  (moves the effective end date earlier)
                 └──────┬──────┘             │
        keys back by    │   keys NOT back    │
        effective end   │   by effective end │
                        ▼                    ▼
                 ┌─────────────┐      ┌─────────────┐
                 │  (settle)   │      │  Overstay   │  daily accrual (derived ramp)
                 └──────┬──────┘      └──────┬──────┘
                        │  KeysReturned       │  KeysReturned
                        ▼                     ▼
                 ┌───────────────────────────────────┐
                 │   Terminal (possession recovered) │  accrual stops; balance persists as debt
                 └───────────────────────────────────┘
```

**`effective end date`** = the elected vacate date, moved **earlier** by
`EarlyReleaseAgreed`, or extended **later** by an overstay until `KeysReturned`.

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
- **Backdating (bitemporality).** A legitimate rent change may be *effective* in
  the past but *recorded* now. Past `RentFellDue` ticks are frozen; the change
  emits `RentChargeAdjusted` deltas. Never mutate history.

---

## 7. Arrears

- **Balance-as-truth.** The fold is a running `Money` balance: `Σ RentFellDue −
  Σ RentPaymentRecorded` (both signed). Negative = credit.
- **Two reads, deliberately divergent:**
  - `weeks_behind` — whole unpaid periods (FIFO, oldest first). A partial payment
    or small credit does **not** decrement it.
  - `balance` — exact dollars; a partial **does** reduce it.
  - There is **no "paid-to date."** (Explicitly rejected as misleading — "we say
    they owe the week.")
- `weeks_behind` generally needs the schedule + FIFO; it collapses to
  `ceil(balance ÷ rent)` only when rent is constant.
- **Projection (read model):** `{ tenancy_id, balance, weeks_behind,
  oldest_unpaid_due_date, as_of }`. Derived, disposable, rebuildable from the log.
  Drives the **~14-day legal arrears trigger**.
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
- **Who builds what** — leaning "Claude drives", with the core learning bits
  (the event fold, the arrears projection, ACL-1) as candidates for
  hand-implementation. To be decided before coding.
