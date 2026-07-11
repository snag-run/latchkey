# ES foundation bake-off — shared slice + scorecard

Throwaway spike (branch `spike/es-bakeoff`) settling the ADR 0002 "when unparked"
question: **raw Commanded + Ash read models** vs **events-as-resources in pure Ash**.
Both implement the *identical* slice below. We score, then write ADR 0003.

Code lives under `lib/spike/` (so Mix compiles it):

- `lib/spike/commanded/` → `Spike.Commanded.*` — raw Commanded aggregate + EventStore
- `lib/spike/ash_events/` → `Spike.AshEvents.*` — event-log resource + hand fold

## Why this exact slice

AshCommanded was rejected (ADR 0002) for a **structural** reason: no `apply/2` fold
feeding a *decision*, so **L7's arrears gate can't be enforced write-side**. So the
bake-off is not "can it persist events" (both can) — it is:

> **Is fold-as-truth structural, or a discipline you can bypass?**

The single discriminating test is the **L7 arrears gate** on `TerminationNoticeGiven`:
the aggregate must **refuse the command unless `days_behind ≥ 14`**, where
`days_behind = as_of − oldest_unpaid_due_date` — computed **from the aggregate's own
fold**, never from an async read model. (domain-model.md §5 L7, §7.)

## The slice (both spikes implement this, verbatim)

One aggregate: `Tenancy` (identity = `tenancy_id`).

### Folded state (the consistency boundary — §4)

| field | meaning |
|---|---|
| `status` | `:pending → :active → :ending` (L2/L3 lifecycle guards) |
| `rent_terms` | `{amount_cents, cycle}` derived from `TenancyCommenced` |
| `due_through` | last due date booked by lazy catch-up |
| `charges` | `[{due_date, amount_cents}]` from `RentFellDue` (FIFO schedule) |
| `payments_total_cents` | `Σ RentPaymentRecorded` (signed) |
| `applied_payment_ids` | idempotency set for `source_payment_id` |

Derived on demand from the fold (§7):

- `balance_cents = Σ charges − payments_total_cents`
- `oldest_unpaid_due_date` = earliest `due_date` whose *cumulative* charge exceeds
  *cumulative* payments (FIFO). A partial payment that doesn't clear the oldest
  period does **not** advance it.
- `days_behind(as_of) = as_of − oldest_unpaid_due_date` (calendar days, `0` if paid up)

### Commands → events

| command | event(s) | guards (aggregate refuses) |
|---|---|---|
| `CommenceTenancy` | `TenancyCommenced` | **L2** — refuse if already commenced |
| `RecordPayment` | `RentFellDue`* then `RentPaymentRecorded` | idempotent on `source_payment_id`; refuse if not active |
| `GiveTerminationNotice` | `RentFellDue`* then `TerminationNoticeGiven` | **L1/L3** must be `:active`; **L7** refuse unless `days_behind(as_of) ≥ 14` |

\* **Lazy catch-up (§6):** before deciding, the aggregate appends a `RentFellDue` for
each due date in `(due_through, min(as_of, end)]`, then advances `due_through`.
Idempotent by the pointer, no global scheduler. Weekly cycle only in the slice.

### Read model (projection — §7)

`{tenancy_id, balance_cents, days_behind, oldest_unpaid_due_date, as_of}` — an Ash
resource, rebuildable from the log. It is a **report**, never the gate.

## Scorecard (filled in `SCORECARD.md` after both run)

1. **Fold-as-truth** — is the L7 gate structurally write-side, or bypassable?
2. **Invariant expression** — how naturally L2/L3/L7 read in code
3. **Concurrency** — optimistic version / expected-version story
4. **Projection wiring** — cost of the Ash read model
5. **ACL / saga fit** (§8, §10) — process-manager story (assessed, not built)
6. **Ceremony** — LOC, modules, extra event-store schema+migrations vs one Postgres
7. **Testability** — pure write-side unit test vs needs EventStore running
8. **Learning value** — how visible the raw ES mechanics are

## Canonical demo (both must produce the same verdict)

Weekly rent $500 (50000c), first due 2026-01-05, `as_of` 2026-01-25:

1. Commence → active.
2. `GiveTerminationNotice` as_of 2026-01-12 (7 days behind) → **REFUSED (L7)**.
3. `GiveTerminationNotice` as_of 2026-01-25 (20 days behind, unpaid) → **ACCEPTED**.
4. Pay oldest week, then notice as_of 2026-01-25 → clock reset FIFO, **REFUSED (L7)**.
