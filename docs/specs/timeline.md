# Spec — Tenancy timeline (evidence-grade, compute-on-read read model)

> Source of decisions: [ADR 0006](../adr/0006-tenancy-timeline-read-model.md) and
> `docs/domain-model.md` §1/§3/§4/§7, `CONTEXT.md` (*Timeline*, *Rental ledger*,
> *Read model · Projection · Compute-on-read*, *The three time axes*). Design issue:
> #5 (the project's deliverable), resolved by ADR 0006. Sizing into vertical-slice
> tickets is a `to-tickets` concern, not decided here.

## Problem Statement

The deliverable is a **tenancy timeline** legible as **NCAT arrears evidence**
(`domain-model.md` §1: "the timeline *is* the event log's payoff") — but it does
not exist. Today the only read model is `Arrears`, a one-row-per-tenancy **summary**
(`balance`, `days_behind`, `oldest_unpaid_due_date`) that answers "how far behind is
this tenancy right now?" It cannot answer the question a tribunal actually asks:
*what happened, in order, and was the termination lawful?* There is no per-event
view showing rent falling due, payments landing, a notice being served, the arrears
at that moment, a payment remedying it, the notice being voided, keys returned, and
the final reckoning — the chronological story that turns an event log into an
exhibit. The rental ledger (a standardized money statement) shows the money but not
the lifecycle narrative or the effective-vs-recorded dimension; a tribunal needs
both, and the narrative half is missing.

## Solution

A **tenancy timeline**: a chronological, event-oriented view of everything that
occurred over one tenancy, served **compute-on-read** — a per-tenancy query that
folds the tenancy's event stream in `occurred_on` order and returns typed entries,
storing nothing. It **complements** the rental ledger (it does not replace it) by
adding the lifecycle/notice narrative the ledger omits and the occurred-vs-recorded
bitemporal dimension a flat money statement can't show. Per ADR 0006:

- **One unified view, typed entries.** **Money rows** (`RentFellDue`,
  `RentPaymentRecorded`, reversals) carry **debit / credit / running-balance**
  columns; **lifecycle markers** (`TenancyCommenced`, `TerminationNoticeGiven`,
  `TerminationNoticeVoided`, `KeysReturned`, `TenancySettled`) are dated narrative
  rows that leave debit/credit blank. Both interleave by date.
- **Sorted by `occurred_on`** (the real-world date the event took place), with a
  secondary `recorded_on` column (when it was booked), muted when equal.
- **`balance_snapshot` and `days_behind` on every row**, folded in `occurred_on`
  order — including on lifecycle markers, where a notice row's balance + days-behind
  *is* the evidence the notice was lawful (L7, s88 ≥14 days).
- **Reversals shown, never hidden** — a negative `RentPaymentRecorded` re-expands
  into the **debit** column at its own `occurred_on`; the original credit row is
  untouched.
- **Derived, rebuildable, faithful** — the timeline adds no integrity mechanism of
  its own; integrity (hash-chaining / verification) is the log's concern (#16).

The reader gets one legible story: *rent accrues → payments land → [14 days pass] →
termination notice served on arrears grounds (balance $1,400, 20 days behind) →
tenant pays → notice voided → keys returned → settled, final balance owing $X.*

## User Stories

1. As a tribunal exhibit reader, I want one chronological view of everything that
   happened over a tenancy, so that I can follow the arrears story end to end
   without cross-referencing separate documents.
2. As a tribunal exhibit reader, I want each rent charge shown as a dated row with
   the period it covers and the amount, so that I can see exactly what was owed and
   when.
3. As a tribunal exhibit reader, I want each payment shown as a dated row, so that I
   can see what was paid and when.
4. As a tribunal exhibit reader, I want a running balance on every money row, so that
   I can see how the arrears grew and shrank over time.
5. As a tribunal exhibit reader, I want the days-in-arrears shown at each point in
   time, so that I can verify the tenant was ≥14 days behind when a termination
   notice was served.
6. As a property manager, I want a termination notice to appear as a dated row
   carrying the balance and days-behind at that moment, so that the exhibit itself
   proves the notice met the L7 arrears ground.
7. As a tribunal exhibit reader, I want a reversed payment shown as its own dated
   **debit** entry (not a hidden edit and not a "negative credit"), so that the
   correction is visible and the ledger stays honest.
8. As a tribunal exhibit reader, I want the original payment row to remain unchanged
   when it is later reversed, so that the record is never mutated after the fact.
9. As a property manager, I want each row to show both the date the event occurred
   and the date it was booked, so that lazy catch-up (booked later than it fell due)
   and pre-entered notices read correctly rather than looking like backdating.
10. As a property manager, I want a rent charge that fell due on the 5th but was
    swept in on the 20th to sort at the 5th (its occurrence date), so that the
    real-world chronology is truthful and the booking lag is merely annotated.
11. As a property manager, I want a termination notice to sort at the date it was
    served, with its take-effect date shown as description, so that "we served
    notice" appears where a tribunal expects it.
12. As a tribunal exhibit reader, I want the tenancy's commencement shown as the
    opening row, so that the timeline has a clear start.
13. As a tribunal exhibit reader, I want keys-returned shown as a dated row, so that
    the moment possession was recovered is captured.
14. As a tribunal exhibit reader, I want the final settlement shown as a punchline
    row stating the final balance (refund owed or debt), so that "this is how it
    ended" is unambiguous.
15. As a property manager, I want payments made after the tenancy is terminal (P4) to
    appear as ordinary credit rows below the settlement row, moving the running
    balance, so that post-exit debt reduction stays visible without altering the
    settlement figure.
16. As a property manager, I want the settlement figure to be exactly the balance
    snapshot on the settlement row, so that there is no separate "final balance" to
    drift from the ledger.
17. As a property manager, I want to open a single tenancy's timeline on demand and
    always see the current state of its recorded events, so that I never read a stale
    materialized copy.
18. As a property manager, I want the arrears **dashboard** (a list of properties
    with current balances) to keep reading the existing `Arrears` summary, so that
    the cross-tenancy view stays fast and the timeline stays a per-tenancy
    drill-down.
19. As a property manager, I want to drill from a dashboard row into that tenancy's
    timeline, so that I can move from "who is behind" to "the full provable story."
20. As a tribunal exhibit reader, I want a reversal to state *why* it happened
    (dishonoured, chargeback) and *which* payment it undoes, so that the correction
    is fully explained rather than left to match by amount.
21. As a property manager, I want a payment reallocated from the wrong tenancy to
    show as a reversal on that tenancy's timeline and a fresh receipt on the correct
    one, so that each tenancy's timeline is honest on its own.
22. As a developer, I want the timeline to display only the integrity-covered dates
    (`occurred_on`/`recorded_on`) and never lean on the physical `created_at` as
    evidence, so that everything shown is backed by the hash-chained,
    integrity-verifiable log (#16).
23. As a developer, I want the timeline to be a pure, deterministic fold that is
    byte-identically reproducible from the log, so that its evidentiary credibility
    reduces to the log's integrity.
24. As a developer, I want the timeline to be a pure read query that never appends to
    the log, so that opening an exhibit can't advance a tenancy's state (catch-up is
    the sweep's job, §6).
25. As a developer, I want each timeline entry typed by kind with a stable field
    shape, so that the presentation layer can render money rows and lifecycle markers
    without special-casing each event.
26. As a developer, I want `balance_snapshot` and `days_behind` computed in the read
    model and never stored on events, so that the occurred-order fold stays correct
    under lazy accrual and no denormalized number can drift.
27. As a developer, I want the timeline to render whatever events currently exist and
    to grow as the exit, notice, and ACL-1 slices land, so that it delivers value now
    without blocking on those slices.
28. As a developer, I want the timeline exercised end-to-end through the existing
    command→read seam, so that the whole loop (dispatch → log → query) is proven, not
    just the fold internals.
29. As a developer, I want the timeline fold unit-testable with no infrastructure, so
    that ordering, snapshots, and reversal-rendering maths are covered fast and in
    isolation.

## Implementation Decisions

- **Compute-on-read, not materialised (ADR 0006 §9).** The timeline is a per-tenancy
  **query** that folds one tenancy's stream in `occurred_on` order and returns typed
  entries — no table, no projector, no rebuild. It is exhibit-only and gates nothing
  (the L7 gate is write-side, §7), so no strong consistency is needed. It is a **pure
  fold — reads the log, never appends** (does not catch up; shows what is booked, §6).
- **New read function, not an extension of `Arrears`.** `Arrears` is summary grain
  (one row per tenancy) and is lossy on payments (`payments_total_cents` scalar), so
  it cannot back per-line entries. The timeline is a separate module in the
  `PropertyManagement` read side that folds the raw stream (mirroring how
  `ArrearsProjector` refolds via `EventStore.stream_forward`, but at event grain and
  at read time rather than on write).
- **Entry shape (the query's return value)** — one entry per event, ordered by
  `occurred_on`:
  - `tenancy_id`, `occurred_on`, `recorded_on`, `kind`
    (`commenced | rent_fell_due | payment | reversal | notice_given |
    notice_voided | keys_returned | settled`),
  - `description`, `debit_cents`, `credit_cents` (money rows only; null on markers),
  - `balance_snapshot_cents`, `days_behind`,
  - `period_from` / `period_to` (money rows spanning a period),
  - `kick_in_date` (payload: `termination_date` / `effective_from`),
  - `reverses` (a reversal → the payment it undoes).
- **Typed entries (ADR 0006 §2).** Money rows fill debit/credit + balance; lifecycle
  markers carry the balance snapshot and days-behind but leave debit/credit null.
- **Sort + dates (ADR 0006 §3–4).** Single sort key `occurred_on`. Two date columns:
  `occurred_on` (primary) and `recorded_on` (muted when equal). Kick-in dates
  (`termination_date`, `effective_from`) are payload rendered in `description`, never
  the sort key.
- **Balance folded in `occurred_on` order (ADR 0006 §4–5).** `balance_snapshot` =
  `Σ debits − Σ credits` over entries up to and including each row, ordered by
  **`(occurred_on, stream_sequence)`** — `occurred_on`, then the event's per-stream
  append position as the canonical tie-breaker for same-day events (not recorded/log
  iteration order left to chance). Final balance is order-invariant, so the
  settlement figure is unambiguous.
- **`days_behind` contract.** Per row, `days_behind = occurred_on −
  oldest_unpaid_due_date` as-at that row (Sydney, ADR 0005 dec. 2/6) **when there is
  an unpaid due date**; when the tenancy is **paid-up** (`oldest_unpaid_due_date =
  nil`, per `domain-model.md` §6), `days_behind = 0` — a stable non-null integer on
  every row, so a paid-up row reads "0 days in arrears" (a credit balance still shows
  in `balance_snapshot`). Both snapshots are **computed in the read model, never on
  events** (ADR 0006 §6).
- **Settlement figure = the snapshot on the `TenancySettled` row** (ADR 0006 §5) —
  not a separate field. Post-Terminal P4 payments are ordinary credit rows below it;
  the settlement row is immutable history and is never overwritten.
- **Reversal rendering (ADR 0006 §7).** Sign selects the column: a negative
  `RentPaymentRecorded` renders in the **debit** column, `kind: reversal`, at its own
  `occurred_on` (`reversed_on`); the original credit row is untouched. `reason` and
  `reverses` come from ACL-1 (see dependency) and render in `description`/`reverses`.
- **Integrity is out (ADR 0006 §8).** The timeline implements no hashing; it is a
  faithful, rebuildable fold whose credibility reduces to the log's (integrity is
  #16's concern — hash-chained/integrity-verifiable, not yet "tamper-evident" until
  #16's anchor tier). It displays only `occurred_on`/`recorded_on`; `created_at` is
  never surfaced as evidence.
- **Dashboard unchanged.** The cross-tenancy arrears dashboard keeps reading the
  materialised `Arrears` projection; the timeline is the drill-down.
- **Pure core, framework-free.** The fold is a pure function over events (like the
  `Tenancy` decide/evolve core); any Commanded/Ash adaptation is a thin edge.

### Dependencies (not built here; the timeline consumes them)

- **Bitemporal envelope retrofit** — events must carry `occurred_on` / `recorded_on`
  (the `effective_date` → `occurred_on` rename, ADR 0006 §3 + Consequences). The
  timeline folds these; without them it can only order by payload dates. This is the
  cross-cutting retrofit ADR 0006 flags for `to-tickets`.
- **ACL-1 `reason` + `reverses`** on `RentPaymentRecorded` (ADR 0006 §7) — built in
  the ACL-1 slice; the timeline renders them when present and degrades to a bare
  "Payment reversed" when absent.
- **Exit + notice events** (`KeysReturned`, `TenancySettled`, overstay `RentFellDue`,
  `TerminationNoticeVoided`) — produced by the exit-settlement and notice slices; the
  timeline renders whatever exists and grows as they land.

## Testing Decisions

- **What a good test asserts here:** behaviour through public APIs only — the
  timeline **query's returned entry list**. Never assert on EventStore tables, the
  aggregate struct internals, or fold internals. Tests describe outcomes ("a rent
  charge and a later payment produce two rows with a running balance that rises then
  returns to zero", "a reversal appears as a debit row at its own date with the
  original credit untouched", "a termination-notice row carries the balance and
  days-behind at service time", "the settlement row's balance equals the final
  reckoning").
- **Seam 1 — the pure timeline fold (unit, no infra).** Feed hand-built event lists
  to the fold function; assert on the ordered entries: `occurred_on` ordering,
  `balance_snapshot`/`days_behind` in occurred-order, reversal→debit re-expansion,
  lifecycle-marker snapshots, the settlement row = its snapshot, muted-vs-shown
  `recorded_on`. Fast; carries most of the logic. **Prior art:** the `Tenancy`
  decide/evolve unit tests.
- **Seam 2 — command → read (integration).** Dispatch real commands
  (`CommenceTenancy`, `RecordPayment`, `CatchUp`, `GiveTerminationNotice`, and the
  exit commands as they land) through the Commanded app + Postgres EventStore, then
  call the timeline query and assert on the entries it returns. Proves the read path
  folds the real log. **Prior art:** the `ArrearsProjector` integration seam (#20 /
  ADR 0003) — same dispatch-then-assert-read shape, except the read model is a query
  result rather than a table row. EventStore reset between runs, as established.
- **No new seam is introduced** — one new read function, tested at the two existing
  seams.
- **Key cases:** commence-only (single opening row); accrual + payment (running
  balance rises then clears; `days_behind` climbs then resets on FIFO clear);
  lazy-accrual ordering (a tick booked late sorts at its occurrence date with a muted
  `recorded_on`); termination notice (marker row carries balance + days-behind
  evidencing L7; sorts at served date, take-effect date in description); reversal
  (debit row at `reversed_on`, original credit untouched, running balance restored);
  settlement (settlement row's snapshot = final reckoning; a post-Terminal payment
  below it moves the balance without altering the settlement row).

## Out of Scope

- **The rental ledger** — the standardized two-column money statement is a separate,
  known-format document (`CONTEXT.md`), not this feature.
- **Materialising a `TimelineEntry` table** — deferred behind the ADR 0006 triggers
  (cross-tenancy line-item queries / fold-on-read latency / server-side
  pagination-filtering).
- **As-of-`T` replay** (fold `recorded_on ≤ T` to show the timeline as known on day
  T) and the **recorded-order forensic balance** — both derivable, built only when a
  forensic/audit need names them (ADR 0006 Deferred).
- **Integrity / hash-chaining** — #16's concern over the log; the timeline adds
  no integrity mechanism (ADR 0006 §8).
- **The bitemporal envelope retrofit, ACL-1 `reason`/`reverses`, and the exit/notice
  events** — dependencies produced by other slices; consumed here, not built here.
- **UI/print styling of the exhibit** — the deliverable is ultimately a printout, but
  this spec defines the read model that backs it, not the print layout.
- **The cross-tenancy dashboard** — served by the existing `Arrears` projection;
  unchanged by this feature.

## Further Notes

- Closes out design issue **#5** (its deliverable was ADR 0006; this is the build
  spec). The timeline is `domain-model.md` §1's stated deliverable — the payoff of
  the whole event-sourced model.
- The one non-local consequence to sequence in `to-tickets`: the **`effective_date`
  → `occurred_on` rename** across existing events, the ADR 0004/0005 event shapes,
  and the exit-settlement spec's envelope references. The timeline depends on it, so
  it likely sequences first.
- The timeline delivers value incrementally: it can render commence / rent-due /
  payment / termination-notice today and gains reversal, exit, and richer notice
  fidelity as the ACL-1 and exit slices land.
