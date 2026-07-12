# 0008 — Property & Tenant identity; the Property Balance seam

Status: **accepted**

## Context

Tenancies were keyed only by a `tenancy_id` slug — no **property** (address) and
no **tenant** (person) anywhere in the model, though `domain-model.md` §3 already
*listed* `property_ref` on `TenancyCommenced` (the code dropped it) and §10 records
names/addresses as evidence-grade PII. The developer-view inspector (#81) needs
each event/stream to say **which property and which tenant** it concerns — a
self-describing row for the tribunal-evidence goal — and the board is scaling
toward ~100 tenancies, where a property recurs across successive tenancies.

## Decisions

### 1. Identity by reference; human labels captured at commencement

`TenancyCommenced` carries **`property_ref`** (a stable property id that recurs
across re-lets) and **`tenants`** — a **list of names** (NSW leases are routinely
joint & several), frozen at commencement (evidence-grade, per §10's
PII-is-evidence posture). Identity is captured **once**, **folded** into `Tenancy`
state, and exposed via a read model for cross-stream display (the firehose) —
**not** stamped on every `RentFellDue` / `RentPaymentRecorded`, which stay on the
`tenancy-<id>` stream and inherit identity by fold.

### 2. Property is a thin identity, not a money aggregate

A **`Property`** is the physical premises: address + the **owner** it's managed
for. It holds **no money invariant** — the §4 independence finding stands
(tenancies are independent; re-letting can legitimately double-charge overlapping
days), so a Property imposes no cross-tenancy consistency. It is thin by nature.

### 3. The Property Balance is a separate downstream aggregate (deferred)

The owner-side money — rent **collected** for the owner **less** management fees,
invoices/bills paid on their behalf, and disbursements out — is a **second running
balance, distinct from and downstream of the tenant balance**, keyed **by
property** (an owner statement outlives any one tenancy). Genuinely stateful → its
own **`Property Balance` aggregate**, not a growth of `Tenancy` or `Property`.
This is the concrete, aggregate-worthy form of §1's out-of-scope *owner statements
/ disbursement / trust-account internals* and §10's *Accounts → double-entry*
directional goal. **Deferred** — built when billing/fees are tackled; named now so
the thin Property and `property_ref` don't foreclose it.

## Consequences

- **Event-contract change:** `TenancyCommenced` gains `property_ref` (reconciling
  doc↔code) and `tenants`; the seeder and the `Tenancy` fold that surfaces identity
  follow. A small **tenancy-identity slice** lands before inspector #81 can display
  property/tenant.
- **`CONTEXT.md`** gains *Property · Property Balance* and *Tenant · joint tenants*.
- **`domain-model.md`** §3 (`TenancyCommenced` payload), §4 (independence-finding
  amendment), and §10 (Property Balance parked) updated.
- Address resolves via the thin **Property** (single source, itself in the
  log/reference), so it is **not** duplicated onto every event; a belt-and-braces
  frozen `property_address` snapshot on `TenancyCommenced` is an easy later add if
  an evidence need names it.

## Considered options

- *Property as a full aggregate now* — rejected: no money invariant today, so it
  would be an invariant-free aggregate. The stateful thing is the Property Balance,
  which is deferred.
- *The owner balance grows the `Tenancy` or `Property` aggregate* — rejected: it's
  a distinct, property-keyed balance that spans tenancies (a management-engagement
  concern, not one tenant's rent and not the bricks), so it earns its own aggregate.
- *Tenant as a `Party` entity* — deferred: over-modeling for a learning sim with no
  cross-tenancy party invariant; names frozen on the event are evidence-grade and
  enough.
