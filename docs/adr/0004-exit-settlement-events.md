# 0004 — Exit-settlement events: `KeysReturned` + `TenancySettled`

Status: **accepted** — finalises the exit-settlement event shapes left as
**(proposal)** in [`domain-model.md`](../domain-model.md) §3/§6/§10 (issue #6).
Pins the events; the accrual/overstay lifecycle that emits them is a later slice.

## Context

`domain-model.md` decided the exit-settlement **rules** (§6) but not the **events** —
`TenancySettled` and `RentChargeAdjusted` sat as `(proposal)`. Grilling the shapes
surfaced that the proposal conflated two genuinely different mechanisms, so the
decision is really several small ones that hang together.

## Decisions

### 1. Two events — an input fact and a reckoning

`KeysReturned` is the **raw input fact** (possession physically recovered on a date);
`TenancySettled` is the **computed reckoning** (the final balance + Terminal
transition). Kept distinct because they *are* distinct in the world — a tribunal
cares about "possession recovered 12 Mar" on its own — and it matches the model's
existing input-fact-vs-derivation split (`PaymentReceived` fact vs
`RentPaymentRecorded` translation; the catch-up `RentFellDue`s).

### 2. Overstay is a crystallised `RentFellDue`, not a field on `TenancySettled` (option ii)

Overstay (keys returned *after* the effective end date E) is the one figure unknown
until `KeysReturned`. It is emitted as a **single** `RentFellDue` covering the
`E → keys` span at the daily-prorated amount (linear ramp ⇒ derive one figure, not N
daily events), **not** as a money-bearing field on `TenancySettled`.

This keeps balance-as-truth *literally* `Σ RentFellDue − Σ RentPaymentRecorded` with
**no special `TenancySettled` term** — overstay is just "rent still falling due, but
daily," which is what §6/A2 already say it is. `TenancySettled` therefore carries
**no money of its own**; it is a pure terminal marker plus a snapshot of the final
balance for the exhibit.

- *Rejected — option (i):* `overstay_charge_cents` as a folded field on
  `TenancySettled`. Fewer events, but it makes `TenancySettled` a money-moving event
  and grows the balance fold a special case. (ii) preserves the clean fold.

### 3. End-of-lease proration is forward (lazy), **not** a backdated correction

A notice always carries a notice period (§11: tenant 14–21 days, landlord 14), so the
effective end date E is known **~2+ weeks ahead** of the boundary period. The boundary
period is therefore always a *future* period when notice lands — it is charged
**pro-rated forward** as it accrues, never charged whole and clawed back. Lazily:
**full rent periods until a full period no longer fits before E, then the remainder is
pro-rated daily to E** (confirmed from a prior session). So there is **no reversal and
no settlement-credit** at exit — the earlier "reverse the boundary week" framing was a
false start.

Backdating (a fact recorded *now* with an effective date in the *past*, forcing
correction of already-posted events) is a **categorically different** mechanism and is
**not** exercised by exit.

### 4. Backdating deferred; corrections use reverse+repost, not a delta

`RentChargeAdjusted` as a `{period, delta, reason}` event is **retired**. When
backdated charge corrections are eventually built (rare — deferred to the rent-increase
slice), the discipline is **reverse-the-wrong-events + re-post-the-corrected-ones** —
the same correction-by-compensation discipline payments already use (§3 reallocation),
and the double-entry-native shape. Nothing here depends on it.

### 5. Bitemporal envelope on events: `{effective_date, recorded_on}`

> **Amended by [ADR 0005](0005-simulation-and-time-model.md) (issue #4).** There is
> no Oban-advanced sim-clock: live time is **wall-clock**. `recorded_on` is reframed
> as "the date the fact was booked *in the simulation*" — **wall-clock for live
> events** (coincides with `created_at`, harmlessly) and **seeder-assigned for
> history** (diverges from `created_at`). The field is **kept**, not retired; that
> divergence is what makes seeded history look accrued-over-time. Envelope *direction*
> is **per-event-kind**: notices forward-date (`effective ≥ recorded`); **accrual
> catch-up ticks lag** (`recorded ≥ effective`) — lazy accrual, *not* backdating.

Every event carries a uniform pair: `effective_date` (when the fact is true in the
tenancy's world) and `recorded_on` (when it was booked). `recorded_on` is **simulated**
time — deliberately distinct from Commanded's EventStore `created_at` metadata, which
is real wall-clock time and is excluded from the #16 hash preimage. **Backdated**
(`effective < recorded` *and* correcting posted events) is the rare deferred case.
Uniform (rather than per-event date names) so the timeline projection (#5) can render
effective-vs-recorded without special-casing each event.

### 6. Refund is declared, not disbursed

When the final balance is negative (tenant overpaid), `TenancySettled` **declares** it
(`final_balance_cents` signed: negative = refund owed, positive = debt) and the balance
**persists** — the exact mirror of §4's "balance persists as debt." PM does not emit a
refund payment: money movement is Accounts' concern, and Accounts is a stub with no
outflow. The actual payout is deferred to the "Accounts → true double-entry"
directional goal (§10) and, when it lands, crosses ACL-1 as a negative
`RentPaymentRecorded` that zeroes the balance — purely additive, forecloses nothing.
"Overstay consumes credit first" and "prepaid excess is refunded" both fall out of
balance-as-truth with no special handling.

## Final event shapes

- **`KeysReturned`** — `{tenancy_id, effective_date (keys date), recorded_on}`. Input
  fact; retires the old `on_date`.
- **overstay charge** (only if keys returned after E) — `RentFellDue{tenancy_id,
  effective_date: E, period_from: E, period_to: keys_date, amount_cents: daily × days,
  recorded_on}`. (`RentFellDue` gains `period_from/period_to`, which §3 already lists
  but the struct is missing.)
- **`TenancySettled`** — `{tenancy_id, effective_date, recorded_on, final_balance_cents}`
  (signed). No money of its own; transitions the tenancy to Terminal.

## Consequences

- **New invariant L9:** `KeysReturned` requires an effective end date (tenancy in
  `Ending`/`Overstay`), reaches Terminal, and fires at most once (L3 keeps Terminal
  final).
- `RentFellDue` grows `period_from/period_to` in code; the fold nets the boundary and
  overstay `RentFellDue`s like any other charge.
- The exit path is **emit-only, forward** — no reversal machinery is needed to ship it.
- `EarlyReleaseAgreed` shortening E into already-charged territory is the one residual
  case that could look backdate-like; it's rare, consensual, and belongs to the
  early-release slice — out of scope here.
