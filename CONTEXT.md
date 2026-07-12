# Ubiquitous language — Latchkey

The glossary for the PM ↔ Accounts payments seam. Terms only; no implementation
details (those live in specs and ADRs). See `docs/domain-model.md` for the model.

## Rental ledger

The **standardized rent statement**: a two-column money document where
`RentFellDue` is a **debit** (charge), `RentPaymentRecorded` a **credit**
(payment), and the running balance is `Σ debits − Σ credits`. A reversal reads
as a debit entry, not a negative credit. This is a **standardized, well-known
format** — not the subject of the timeline design. It is *not* full double-entry
bookkeeping (balancing contra postings); that is Accounts' native model and a
`domain-model.md` §10 directional goal. See `domain-model.md` §7.

## Timeline

The **feature under design (issue #5)**: a chronological, event-oriented view of
everything that occurred over a tenancy — rent falling due, payments, notices,
voids, keys returned, settlement — legible as **tribunal (NCAT) arrears
evidence**. It **complements the rental ledger** (it does not replace or contain
it): the timeline adds the lifecycle/notice narrative the ledger omits and the
**occurred-vs-recorded** (bitemporal) dimension a flat money statement can't
show. Derived, not recorded; renders the live tenancy, not a frozen snapshot.

## Read model · Projection · Compute-on-read

The **event log is the one source of truth** (each tenancy's stream of events).
A **read model** is any query-shaped view *derived* from the log — disposable and
rebuildable; the truth is never stored in it, only re-derived by folding events.
A read model is served one of two ways:

- **Materialised read model (a "projection")** — the fold runs **on write**: a
  *projector* (a Commanded event handler) refolds the stream as each event
  arrives and keeps a **table** fresh. Right when the view is queried **across
  many** tenancies. Example: **`Arrears`** — `ArrearsProjector` upserts the
  `pm_tenancy_arrears` table; the arrears **dashboard** reads it.
- **Compute-on-read read model (a *query*)** — the fold runs **on read**: fold one
  tenancy's stream at query time, store **nothing**. Right when the view is seen
  **one** tenancy at a time and the stream is small. Example: the **`Timeline`**
  (issue #5) — a per-tenancy drill-down, no table, no projector.

"Projection" (strict sense) = the materialised kind. The timeline is *not* a
projection in that sense — it's a compute-on-read query.

## The three time axes

An event carries two domain dates in its envelope; the store adds a third,
physical one. Kept distinct because they diverge and the timeline renders the
divergence (supersedes the `effective_date` framing of ADR 0005 §3–4 — see
ADR 0006):

- **`occurred_on`** — *when the event took place* in the tenancy's real world:
  rent's due date, a payment's received date, a notice's **served** date, the
  keys date, the settlement date. Uniform across every event kind. This is the
  timeline's primary/sort date (lay column header: "Date").
- **`recorded_on`** — *when the fact was booked* into the record. Coincides with
  `occurred_on` for live events; **lags** it for lazy accrual (rent due 5 Mar,
  swept in 20 Mar). Seeder-assigned for backhistory (ADR 0005 §3).
- **`created_at`** — the store's *physical insert* wall-clock. Provenance/tamper
  only; excluded from the #16 hash preimage.

**Not** a time axis: a **kick-in date** — the forward date a *notice announces*
(a rent increase's `effective_from`, a termination's `termination_date`). It is
the event's **payload**, shown in the row's text ("takes effect 15 Mar"), never
the sort key. Distinguishing kick-in from `occurred_on` is why "effective_date"
was retired here — it conflated the two.
