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

## Property · Property Balance

A **Property** is the physical rental premises — a **thin identity** (address, and
the **owner** it is managed for). It carries **no money invariant of its own**:
tenancies are independent and re-letting can legitimately double-charge overlapping
days (`domain-model.md` §4), so a Property imposes no cross-tenancy consistency. A
tenancy names its property by a stable **`property_ref`** that **recurs across
successive tenancies** of the same premises — a **non-PII** key carried on
`TenancyCommenced` (ADR 0008).

A **Property Balance** is the **owner-side running balance** for a property: rent
**collected** on the owner's behalf, **less** management fees, invoices/bills paid
for them, and disbursements out. It is a **second running balance, distinct from
and downstream of the tenant balance** (the tenant pays rent → the property's owner
ledger is credited, net of fees). Keyed **by property** — an owner statement
outlives any single tenancy — it is genuinely stateful and earns **its own
aggregate**. **Parked**: the concrete form of §1's out-of-scope *owner statements /
disbursement / trust-account* and §10's *Accounts → double-entry* goal; built when
billing/fees are tackled (ADR 0008).

## Tenant · joint tenants

The **party or parties** on the lease. A tenancy may have **several co-tenants**
(NSW residential leases are routinely **joint & several**), so a tenancy's
**tenants** are a **list of names**. Names are **PII kept out of the immutable log**
(ADR 0008): they live in the **Directory** (below), keyed by `tenancy_id`, and are
resolved for display — the log carries only the non-PII `property_ref`. Distinct from
the **tenant balance**, which is the tenancy's rent-ledger position (the *Rental
ledger* above).

## Agent — simulated vs human

The **agent** is the property-manager side of a tenancy: the party who issues a
termination notice, takes back keys, would agree a repayment plan. Two provenances,
both producing the *same* domain events:

- **Simulated agent** — the ambient world engine (ADR 0011) driving agent-side
  events **AFK** from a deterministic **agent archetype** (a *notice threshold*:
  `strict` = notice at L7/14 days behind, `lenient` = 30). Notice and vacate dates
  are **derived** from the arrears trajectory, not authored. This is the default in
  the current "watch a simulated world" deliverable.
- **Human agent** — a person driving those same events interactively ("play the
  agent"). The original ADR 0005 framing, **deferred** (reversible) under ADR 0011.

Distinct from the **tenant**, the *other* simulated actor (pays / short / late /
misses), and from the **Directory** identity below.

## Directory

A **disposable, non-event-sourced read model** (`Latchkey.Simulation.Directory`, in
the **Simulation** Ash domain) mapping `tenancy_id →` the tenant **names** and
**property address** for display. It is the home for identity **PII**, deliberately
**outside the append-only log** (ADR 0008): regenerable, erasable, never part of the
evidence chain. The inspector renders identity by merging a Directory row with the
tenancy's `Arrears` row in Elixir — no PII off the raw log, no cross-schema join.

## Re-let vs co-tenant change

A **re-let** is a genuinely **new tenancy** on the **same premises**: a distinct
`tenancy_id` and new tenants, sharing the prior tenancy's **`property_ref`**, and
commencing only **after that prior tenancy reached terminal** (keys returned). The
shared `property_ref` — carried on the log (ADR 0008) — is what makes "these
successive tenancies are the same premises" a first-class fact; on the display side
the two legs resolve to the **same address** but **different tenants** (address keys
off `property_ref`, name off `tenancy_id`). Re-letting can legitimately double-charge
overlapping days, since tenancies stay independent (`domain-model.md` §4).

A **co-tenant change** is **not** a re-let and **not** a new tenancy: a joint tenant
swapping out (one name off the lease, another on) stays **within the existing
tenancy** — same stream, same `tenancy_id`, same `property_ref`, an unbroken ledger.
It is **never** modelled as a second stream. Only premises re-lets (prior tenancy
fully terminal, then a new tenancy) begin a new stream.

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

## Vacant possession · `V` vs `E`

**Vacant possession (`V`)** — the inked date the tenant actually hands back
possession (keys returned). It is the **reckoning point**: the exit settlement
(final pro-ration, arrears, refund) is computed *against `V`*, not against the
notice's effective end date.

**Effective end date (`E`)** — the date the termination notice takes effect. It
is **not** the reckoning point. It is the **earliest-permissible** end date and
the **clamp for live accrual** while `V` is still unknown (a live tenancy can't
be reckoned to a keys date that hasn't happened yet).

The two diverge, and which side they fall on is the whole shape of the exit:

- **Overstay (`V > E`)** — the tenant holds over; possession recovered *after*
  `E`. The exit **appends** the extra `[E, V)` accrual (issue #32).
- **Same-day (`V = E`)** — possession recovered exactly on `E`; the `[E, V)` span
  is empty, so **neither** an overstay charge nor an early-leave correction — the
  boundary period simply pro-rates to `E = V`.
- **Early leave (`V < E`)** — legitimate early hand-back (sale, old no-grounds);
  possession recovered *before* `E`, so periods booked out to `E` were
  **over-charged** and need a **correcting entry** — a visible reversal, never a
  silent un-charge (issue #64).

The exit is **always a forward append** against the append-only log: reckoning at
`V` never rewrites or re-pro-rates already-booked periods.

## The three time axes

An event carries two domain dates in its envelope; the store adds a third,
physical one. Kept distinct because they diverge and the timeline renders the
divergence (supersedes the `effective_date` framing of ADR 0005 decision 4 — see
ADR 0006):

- **`occurred_on`** — *when the event took place* in the tenancy's real world:
  rent's due date, a payment's received date, a notice's **served** date, the
  keys date, the settlement date. Uniform across every event kind. This is the
  timeline's primary/sort date (lay column header: "Date").
- **`recorded_on`** — *when the fact was booked* into the record. Coincides with
  `occurred_on` for system-managed accrual: a `RentFellDue` books on its **own due
  date** (ADR 0010, supersedes ADR 0005 §4 — no lazy-accrual lag). It **lags**
  (`recorded_on > occurred_on`) only for an **imported/transferred** tenancy whose
  history is rebuilt after the fact (issue #117) — that is what the inspector's
  divergence flag now means. Seeded backhistory is booked at its historical dates,
  still distinct from the seed-run `created_at` (ADR 0005 §3).
- **`created_at`** — the store's *physical insert* wall-clock. Provenance only;
  excluded from the #16 hash preimage.

**Not** a time axis: a **kick-in date** — the forward date a *notice announces*
(a rent increase's `effective_from`, a termination's `termination_date`). It is
the event's **payload**, shown in the row's text ("takes effect 15 Mar"), never
the sort key. Distinguishing kick-in from `occurred_on` is why "effective_date"
was retired here — it conflated the two.
