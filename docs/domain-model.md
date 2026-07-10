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
correction-by-compensation. **Priority:** the domain model (the tenancy lifecycle,
the arrears gate, the ACL seam) is the first-class deliverable; event sourcing is
the *enabling* implementation — built Ash-native — not the goal itself (see §2 and
ADR 0001).

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

**Domain modelling is the first-class concern; event sourcing is the supporting
implementation** that makes the tamper-evident timeline fall out almost for free.
Built **Ash-native** — Ash 3 / AshPostgres, CQRS/ES via **AshCommanded** (the
Commanded library + its Postgres EventStore as source of truth).
The write model is genuinely event-sourced: state is **derived from the fold**,
never a mutated status column — so **no `AshStateMachine`** (the §4 state machine
lives on as domain rules over derived state, not a stored status). A hand-rolled,
frameworkless ES core is a **parked, optional descent** (§10), not the spine.
**(decided — see [ADR 0001](adr/0001-domain-first-ash-native-es.md))**

- **One physical event store** (a single append-only Postgres table). Simplest
  thing that works; in-process, no separate services. **(decided)**
- **Logical ownership is per-context.** Every event has exactly one owning
  context. A consumer **never folds another context's event directly** — it
  **translates at its ACL** into its own language first. The shared table is
  *transport*; the boundary lives in the *translation*. **(decided)** A translating
  ACL that **emits** events (ACL-1) is a **stateful policy with its own checkpoint**,
  *not* a side-effect-free projection — see §8 for its replay semantics.
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
- **arrears fold** — enough to re-derive **FIFO oldest-unpaid** at decide-time. Two
  equivalent shapes: (a) the **ordered charge sequence** (each `RentFellDue`'s
  `due_date` + `amount`) alongside **Σ payments applied**, re-deriving FIFO on demand;
  or (b) an **`oldest_unpaid_due_date` pointer** maintained directly, advanced as FIFO
  periods clear. Either yields `oldest_unpaid_due_date` → `days_behind`, which the L7
  gate needs (§5). A **scalar balance alone is lossy**: it collapses the schedule to
  one number and can't recover *which* period is unpaid, so it can't drive the gate.
  The running **balance** (`Money`, negative = credit; `Σ charges − Σ paid`) remains a
  **view over this fold** for the exit refund — not the fold itself.
- set of applied `source_payment_id`s (idempotency)

**Structural finding:** tenancies are **independent** — there is **no `Property`
aggregate** above them. Re-letting can legitimately double-charge two tenancies
for the same days (an overstaying tenant still liable while the incoming tenancy
has commenced), so nothing needs cross-tenancy consistency **on the money**.

**But possession is singular.** Only one tenancy can hold **vacant possession** of
the property at a time: the incoming tenancy cannot actually take possession until
the outgoing tenant returns keys (`KeysReturned`). So the double-charge is
legitimate on *liability*, not on *physical possession* — and that constraint lives
in the real world (and in Leasing's hand-over), **not** in a cross-tenancy aggregate
invariant. The independence finding stands; this only flags what the money model
doesn't see.

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
  *not* the dollar amount owed. This is a **write-side invariant**: `decide` computes
  `days_behind` from the aggregate's **own fold** (§4) and refuses the command — it is
  **not** read off the async arrears projection. The projection may mirror the same
  number for the exhibit, but the gate does not depend on it.
- **L8** — Paying the arrears in full **— or entering and complying with an agreed
  repayment plan —** before the termination date **voids** the termination notice;
  the tenancy continues (a fresh notice may issue if they fall behind again). *(The
  NSW "general guarantee" against termination for remedied arrears.)* **Caveat
  (deliberate omission):** the guarantee is **not absolute** — a tribunal may still
  order termination where the tenant has *frequently failed to pay* rent on time; that
  tribunal finding is **out of scope** and not modelled. Note too that "comply with a
  plan" is modelled here as a **clean void → `Active`**; whether it should instead be a
  **conditional suspension** (a later breach revives the termination) is parked in §10.

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
- **`RentFellDue` via catch-up (command-time + sweep).** The aggregate advances its
  own clock by appending a `RentFellDue` for each due date in
  `(due_through, min(today, effective_end_date)]`, then moving `due_through`.
  Idempotent by the pointer; needs no global scheduler for correctness. **Catch-up runs
  only inside commands and the Oban sweep — never in a query.** Queries are **pure
  folds**: they read the log, they never append to it. Consequently the **nightly sweep
  is load-bearing, not cache-warming** — an untouched tenancy's timeline (and its
  `days_behind`) is genuinely **stale until a command or the sweep advances it**, not
  merely un-warmed.
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
    balance does *not* accelerate it; only the clock does. **This is the quantity the
    L7 gate tests** (`days_behind ≥ 14`) — but the gate computes it **write-side in
    `decide`** from the aggregate fold (§4, §5 L7), *not* from this projection.
    Clearing the oldest unpaid period (FIFO) advances
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
  oldest_unpaid_due_date, as_of }`. Derived, disposable, rebuildable from the log —
  and **report/exhibit only**. It does **not** gate any command: the L7 arrears gate is
  a write-side invariant computed in `decide` (§5 L7), so an *async* projection can
  never be the precondition for refusing `TerminationNoticeGiven` — a stale read must
  not authorise a termination. *(Alternative considered: make just this projection
  **inline/synchronous** with the command instead of moving the gate into the
  aggregate. Weighed and set aside — the §4 fold already carries what `decide` needs,
  so the gate lives write-side and the projection stays pure exhibit.)*
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
- **A replay-safe policy, not a projection.** ACL-1 has a **side effect** — it emits
  `RentPaymentRecorded` — so it cannot be blindly re-run like a side-effect-free
  projection. It keeps its **own checkpoint** over the Accounts stream and is
  **idempotent on `source_payment_id`**. On a full-store replay it translates only
  Accounts events **past its checkpoint**; the `RentPaymentRecorded` events it already
  emitted are simply **re-folded** into the aggregate, never re-translated. This is the
  one place the "consumers translate; projections are pure" discipline (§2) is
  deliberately bent — the checkpoint is what makes the side effect replay-safe.
- **Idempotent** on `source_payment_id`.
- Fires **only for tenancy-attributed receipts**. `UNKNOWN`/suspense payments
  never cross the seam — PM's arrears is never polluted by unmatched money.
- **Defensive:** reject a reversal that references a payment PM never recorded — see
  §10 for the "not seen *yet*" vs "will *never* see" wrinkle once Accounts un-stubs.

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
- **Repayment plan: conditional suspension vs one-shot void (§5 L8, §4 SM).** The
  general guarantee holds only *while the tenant keeps complying*; a breach revives the
  termination. Should a plan introduce a **plan-active sub-state + `RepaymentPlanBreached`**
  transition (back to `Ending`) rather than the clean void → `Active` L8 and the state
  machine show today? Deferred — **to grill.**
- **P2 reversal ordering: "not seen *yet*" vs "will *never* see" (§5 P2, §8 ACL-1).**
  Today the single, totally-ordered store guarantees receipt-before-reversal, so
  "reject a reversal PM never recorded" is safe. Once Accounts **un-stubs / goes
  out-of-process**, a reversal arriving ahead of its receipt is mere reordering — yet
  it looks **identical to a seam bug**. Distinguish *not-yet-arrived* (park/hold
  pending) from *never-coming* (reject), e.g. via a watermark or a pending-reversals
  holding area. Deferred — **to grill.**
- Whether `RentTerms` is a standalone VO or bare aggregate fields — minor.
- **Collections beyond the notice** — Tribunal (NCAT) escalation and non-arrears
  termination grounds are **out of scope**; the notice → void → (lapse) boundary is
  captured, the tribunal internals are not.
- **Who builds what / how** — built **Ash-native** (Ash 3 / AshPostgres, CQRS/ES via
  AshCommanded + Commanded), David driving the domain modelling. See ADR 0001.
- **Hand-rolled ES descent (optional, parked).** Dropping to a frameworkless ES
  core — to feel the append / fold / optimistic-concurrency mechanics AshCommanded
  (and Commanded, and even Go) absorb — is a *maybe*, not committed. If taken, it's a clean-slate rewrite
  (that's the exercise), so the Ash build pays for **no speculative peelability
  seams**. See ADR 0001.
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

- **Arrears termination (s88).** The statute: a non-payment termination notice "has no
  effect unless the rent has ... remained unpaid ... for **not less than 14 days**
  before the ... notice is given" — i.e. **≥ 14 days**, which is exactly what L7's
  `days_behind ≥ 14` encodes (inclusive at 14). NSW Gov consumer material paraphrases
  this loosely as "more than 14 days"; the **statute wording controls**. The notice
  then gives the tenant **14 days** to vacate and must state they need not leave if they
  pay all rent owing **or** enter and **fully comply with** an agreed **repayment plan**
  (the "general guarantee" — L8).
- **Time, not amount (recorded rationale).** s88 counts *days the rent has remained
  unpaid*, not *dollars owed*. Tenant-facing summaries blur this into "owe 14 days'
  rent **or** be 14 days overdue"; we deliberately **reject the amount framing** and
  read the ground as **time-elapsed only** (§7 `days_behind`). Someone 8 days late who
  happens to owe "14 days' rent" is **not** 14 days in arrears, and the notice would
  not stand — which is why the amount-based reads (`balance`, `periods_behind`) are
  never the legal gate.
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
