# 0006 — Tenancy timeline: an evidence-grade, compute-on-read read model

Status: **accepted** — resolves issue #5, the project's deliverable
(`domain-model.md` §1: the timeline *is* the event log's payoff). **Supersedes
[ADR 0005](0005-simulation-and-time-model.md) decision 4** (envelope direction —
the "notices forward-date, `effective_date` = kick-in" framing): `effective_date`
is renamed `occurred_on` (occurrence, uniform) and kick-in dates are payload.
**`recorded_on` and `created_at` (decision 3) are retained unchanged** — no
`recorded_on` rename is implied. The rest of ADR 0005 stands. ADRs are immutable,
so 0005's body is untouched — only its Status line points here.

## Context

`domain-model.md` §1 makes the **tenancy timeline** the deliverable: a complete,
**append-only, auditable** history of a tenancy legible as **NCAT arrears
evidence** (the stronger "tamper-evident" claim awaits #16's deferred anchor
tier — see decision 8). The
model settled the *facts* (events, the bitemporal envelope, exit settlement) and
the *arrears reads* (§7), but not what the timeline **shows**, how it renders the
bitemporal pair legibly, or how it is **served**. #5's blockers (#3 ES foundation,
and the exit + simulation ADRs 0004/0005 that supply the events it renders) are
closed.

Grilling surfaced that `effective_date` was **overloaded** — it conflated *when
an event occurred* with *when the change a notice announces kicks in* — and that
the biggest structural call is not the schema but **materialise vs compute-on-read**.

## Decisions

### 1. Timeline and rental ledger are two artifacts; the timeline complements the ledger

The **rental ledger** is the standardized rent statement (a two-column money
document: `RentFellDue` = debit, `RentPaymentRecorded` = credit, running balance
= Σ debits − Σ credits; a reversal reads as a *debit*, not a negative credit).
It is a known format and **out of scope** for #5. The **timeline** is the feature
under design: a chronological, event-oriented view that **complements** the
ledger — it adds the **lifecycle/notice narrative** the ledger omits and the
**occurred-vs-recorded** dimension a flat money statement can't show. (See
`CONTEXT.md`.) This is *not* full double-entry bookkeeping (balancing contra
postings) — that is Accounts' native model and a §10 directional goal.

### 2. One unified chronological view with typed entries

The timeline is a single time-ordered view of **typed** entries:

- **Money rows** (`RentFellDue`, `RentPaymentRecorded`, reversals) carry
  **debit / credit / running-balance** columns — the ledger's money semantics.
- **Lifecycle markers** (`TenancyCommenced`, `TerminationNoticeGiven`,
  `TerminationNoticeVoided`, `KeysReturned`, `TenancySettled`) are dated
  narrative rows that leave the debit/credit columns blank.

So the timeline is a **superset** of the ledger's money view plus the narrative —
"complements" made concrete. A tribunal reads one story: rent accrues → payments
land → *[14 days pass]* → notice served on arrears grounds → tenant pays → notice
voided → keys returned → settled.

### 3. The `occurred_on` / `recorded_on` / `created_at` split (supersedes 0005 dec. 4)

`effective_date` conflated two things that split at the notice case:

- **`occurred_on`** — *when the event took place* in the tenancy's real world
  (rent's due date, a payment's received date, a notice's **served** date, the
  keys date, the settlement date). **Uniform across every event kind.**
- **A kick-in date** — the forward date a *notice announces* (a rent increase's
  `effective_from`, a termination's `termination_date`). This is **payload**,
  shown in the row's text ("takes effect 15 Mar"), **never** the sort key.

ADR 0005 decision 4 put the kick-in date into `effective_date` for notices. But
by the envelope's own rule — *effective = when the fact is true* — a
`TerminationNoticeGiven`'s fact is *the giving*, true on the **served** date. So
`effective_date` is **renamed `occurred_on`** and means occurrence uniformly;
the kick-in date stays payload. `recorded_on` (when the fact was **booked**;
lags `occurred_on` for lazy accrual, seeder-assigned for history) and the store's
physical `created_at` (provenance only, excluded from #16's hash preimage)
are unchanged. See `CONTEXT.md` "The three time axes."

### 4. Sort by `occurred_on`; two date columns

The timeline sorts by **`occurred_on`** — the real-world chronology — with a
**canonical tie-breaker** for events that share an `occurred_on`. Because row
order drives the running `balance_snapshot`, `days_behind`, and the byte-identical
reproducibility claim (§8), a single date key is *not* a total order and must not
be left to rely on incidental EventStore iteration order. The tie-breaker is the
event's **per-stream sequence number** (its append position within the tenancy's
stream) — a stable total order the store already assigns — with the event id as a
final fallback. So the fold sorts explicitly on **`(occurred_on, stream_sequence)`**.
Same-day money events therefore fold in booking order, which keeps the running
balance deterministic and identical on every rebuild.

It shows **two date columns**: `occurred_on` (primary; lay header "Date") and
`recorded_on`, the latter muted/blank when equal (the common live-event case, so
no noise). The earlier per-event-kind "anchor" wrinkle **dissolves**: a
forward-dated notice (served 1 Mar, takes effect 15 Mar) now sorts to its **served
date (1 Mar)** — where a tribunal expects "we served notice" — with 15 Mar as
in-row description. One rule, no per-kind logic.

### 5. `balance_snapshot` + `days_behind` on every row, folded in `occurred_on` order

Every row carries two **as-at snapshots**: `balance_snapshot` and `days_behind`,
computed as-at that row's `occurred_on`. Money rows *additionally* carry
debit/credit.

- **Folded in `occurred_on` order** — the real-world chronology, not the log's
  recorded/append order. These differ under lazy accrual (rent due 5 Mar, swept
  in 20 Mar, a payment received 10 Mar): occurred-order tells the honest "what
  was actually owed when" story; the tenant owed rent from the 5th regardless of
  when the sweep booked it. The **final** balance is order-invariant (Σ commutes),
  so the settlement figure is unambiguous; only intermediate running balances
  depend on the order, and occurred-order is the truthful one.
- **The snapshots on lifecycle markers are themselves evidence.** A
  `TerminationNoticeGiven` row showing `balance $1,400 · 20 days in arrears`
  proves the notice was lawful under **L7** (§5, s88 ≥14 days) — the money-shot
  of an arrears exhibit.
- **`TenancySettled`'s `final_balance_cents` is not a special field** — it is
  simply the `balance_snapshot` on that row. Post-Terminal P4 payments appear as
  ordinary credit rows *below* it and keep moving the running balance; nothing
  overwrites the settlement row (immutable history). The exit spec's
  "snapshot vs current, two fields" concern is a *storage* concern for the flat
  `Arrears` summary; on the per-row timeline there is nothing to overwrite.

### 6. Balance snapshots live in the read model, never on the events

`balance_snapshot` is **derived in the timeline read model**, not stored on the
domain event. It **cannot** live on the event: the display balance folds in
`occurred_on` order while events append in `recorded_on` order, so a
later-appended-but-earlier-occurred event (a lazy tick) **retroactively changes**
the correct balance of rows after it — a number frozen at append time would be
provably wrong. The snapshot is inherently non-local (a function of the whole
occurred-sorted set), so it belongs to the fold, not the fact.

Integrity verification does **not** need it: hash-chaining the *facts* (charges, payments)
and the balance is reproducible from them (recompute → must match). Storing a
derived balance in the hash preimage would be redundant and couple the chain to
fold logic. If folding ever becomes a *performance* pain, the lever is
**aggregate/projection snapshotting** (Commanded supports it), not denormalising
balance into event payloads.

### 7. Reversals and corrections are shown, never hidden

The event model stores a reversal as a *negative* `RentPaymentRecorded` (the fold
absorbs it), but the timeline **re-expands** it into the **debit column** (§7: "a
debit entry, not a negative credit"):

- Sign picks the column — negative `RentPaymentRecorded` → debit, positive →
  credit. The reader never sees a "negative credit."
- The reversal appears at its **own** `occurred_on` (`reversed_on`), a *new* row;
  the original credit row stays put, **unaltered**. Pure correction-by-
  compensation (§3 reallocation = reverse + repost), never mutation.
- Cross-tenancy reallocation stays honest per-timeline by construction: the wrong
  tenancy gets the reversal (debit), the right tenancy the fresh receipt (credit).

**Event-shape requirements on the ACL-1 slice** (built there, consumed here):
`PaymentReversed`'s `reason` and its `reverses` (original payment) link must
**propagate through ACL-1 into `RentPaymentRecorded`**, so a row can read
"Payment reversed — dishonoured" and explicitly tie to the payment it undoes.

### 8. Integrity is the log's concern (#16), not the timeline's

Integrity is a property of the **log**, not the read model. **#16 (hash-chaining)**
makes the log **append-only and integrity-verifiable** — re-verification detects
after-the-fact alteration, deletion, or reordering. Per #16's honesty guardrail,
that tier is **not** full *tamper-evidence*: an operator with DB write access can
recompute the whole chain after editing a row, so the "tamper-evident" claim
awaits #16's **deferred external-anchor tier**. Until then this ADR (and the
timeline spec) say **"hash-chained / integrity-verifiable"** or **"append-only,
auditable,"** never "tamper-evident."

The timeline is a **deterministic, rebuildable** fold whose credibility **reduces
to the log's** — anyone can re-derive it byte-identically and #16's verification
detects a broken chain. So the timeline implements **no hashing of its own**. The
evidence-quality AC splits: **#16 provides integrity verification; #5 provides
legibility + faithfulness** (a faithful, rebuildable fold; corrections shown never
hidden; it displays only the integrity-covered dates `occurred_on`/`recorded_on`
and never leans on `created_at` as evidence). **#5 ⊥ #16 — neither blocks the
other.** A "verify this exhibit against the log" affordance is a later capability,
not #5.

### 9. Compute-on-read, not materialised

The timeline is served **compute-on-read**: a per-tenancy **query** that folds one
tenancy's stream in `occurred_on` order when opened, storing **nothing** — not a
materialised projection with a table and projector. Justified because it is viewed
**one tenancy at a time** (drill-down detail), streams are small, it is
exhibit-only (nothing dispatches off it — §7's L7 gate is write-side, so no strong
consistency is needed), it is always consistent with the log, and it matches §6's
"queries are pure folds — they read, never append" (it shows what is booked; the
sweep owns booking).

The **cross-tenancy arrears dashboard** — a list of properties with current
balances — is a *different read model at a different grain*: the **`Arrears`
projection** (materialised, `ArrearsProjector` → `pm_tenancy_arrears`), which
already exists and caches the current balance per tenancy. It is queried *across*
tenancies, so it *must* be a table. The timeline is the drill-down opened from a
dashboard row. Textbook CQRS: **materialise the read queried across entities;
compute-on-read the detail viewed one entity at a time.** (See `CONTEXT.md`
"Read model · Projection · Compute-on-read.")

- *Rejected — materialise a `TimelineEntry` table from the start:* because
  `balance_snapshot` folds in `occurred_on` order while events append in
  `recorded_on` order, a materialised timeline could not simply *append* — a lazy
  tick forces a **re-fold-and-rewrite of the whole tenancy's rows**. That cost buys
  nothing at this grain/scale, and the cross-tenancy need it would serve is already
  met by `Arrears`. Deferred behind explicit triggers (below).

## Entry shape (the query's return shape)

One entry per event, sorted by `(occurred_on, stream_sequence)`:

```text
tenancy_id · occurred_on · recorded_on · kind
  (commenced | rent_fell_due | payment | reversal | notice_given |
   notice_voided | keys_returned | settled) ·
description · debit_cents · credit_cents ·
balance_snapshot_cents · days_behind ·
period_from · period_to ·           # money rows spanning a period
kick_in_date ·                      # payload: termination_date / effective_from
reverses                            # reversal → the payment it undoes
```

Money rows fill `debit_cents`/`credit_cents`; lifecycle markers leave them null.
This is the shape the compute-on-read **query returns**, not a stored table.

## Consequences

- **[ADR 0005](0005-simulation-and-time-model.md) Status line** updated: decision 4
  (envelope direction / `effective_date` semantics) superseded here; `recorded_on`
  (decision 3) retained; body untouched.
- **`CONTEXT.md`** gains: *Rental ledger*, *Timeline*, *Read model · Projection ·
  Compute-on-read*, and *The three time axes*.
- **Envelope field rename** — `effective_date` → **`occurred_on`** across events,
  a cross-cutting retrofit for a build ticket (touches the events, ADR 0004/0005
  event shapes, and the exit-settlement spec's envelope references). Kick-in dates
  stay payload (`termination_date`, `effective_from`).
- **Event-shape requirements on the ACL-1 slice**: `RentPaymentRecorded` gains
  `reason` and `reverses`, propagated by ACL-1 from `PaymentReversed`.
- **`days_behind` per row** is computed as-at each row's `occurred_on` (Sydney,
  ADR 0005 decision 2/6) — consistent with the on-read `days_behind` rule — and is
  **`0` when the tenancy is paid-up** (`oldest_unpaid_due_date = nil`, §6), so every
  row carries a stable non-null integer.
- Feeds **`/to-spec`** next (this ADR is the design; the spec + tickets follow the
  grill → to-spec → to-tickets flow).

## Deferred (gated triggers — not open "laters")

- **Materialise `TimelineEntry`** — gated on **any** of: (a) a cross-tenancy
  line-item query is needed (e.g. "all reversals this month"); (b) fold-on-read
  latency becomes noticeable as streams grow; (c) the UI needs server-side
  pagination/filtering. Until then, compute-on-read.
- **As-of-`T` replay view** (fold `recorded_on ≤ T` to show "the timeline as known
  on day T") — event-sourcing gives it for free; **built when a forensic/audit
  need names it**, not now.
- **"What the system believed at append time"** (recorded-order running balance) —
  a legitimate, still-derivable forensic view; **gated on an actual audit need**.
- **Aggregate/projection snapshotting** for stream-size performance — gated on
  fold-on-read latency (same trigger (b) above).
