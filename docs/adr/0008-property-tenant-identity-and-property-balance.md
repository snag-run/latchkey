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

### 1. Identity by reference; PII in a disposable directory, not the log

`TenancyCommenced` carries **`property_ref`** — a **non-PII** stable property id
that recurs across re-lets — and nothing else identity-bearing. Human labels
(**tenant names** and the **property address**) are **kept out of the immutable,
public log**: they live in a disposable, **non-event-sourced** read model,
`Latchkey.Simulation.Directory` (keyed by `tenancy_id`), resolved into the inspector
at render by an in-Elixir merge with the `Arrears` row — no PII off the raw log, no
cross-schema join. This is the "reference-only events" option §10 flagged: id/ref in
the log, PII in a mutable table.

**Invariant:** no PII is ever written to the event log; log identity fields are a
**non-PII allowlist** (`property_ref`, `tenancy_id`). This is an *enforced control*,
not a synthetic-data assumption — the public `/inspector` (D6) can render every
stored event without exposing names or addresses. `property_ref` stays in the log
because it is non-PII and **structural**: it makes "these successive tenancies are
the same premises" a first-class log fact (needed as the board scales to ~100
tenancies), rather than a guess reconstructed from a disposable table.

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

- **Event-contract change:** `TenancyCommenced` gains **`property_ref`** only
  (reconciling doc↔code) — **not** tenant names. The seeder sets it; no PII enters
  the log.
- **New read model:** `Latchkey.Simulation.Directory` — a **second Ash domain**
  (`Simulation`, alongside `PropertyManagement`) holding `{tenancy_id → tenant names,
  property address}`. **Disposable, non-event-sourced, regenerable**: the PII home.
  The inspector merges it with the `Arrears` row in Elixir at render (#81).
- **`CONTEXT.md`** gains *Property · Property Balance*, *Tenant · joint tenants*, and
  *Directory*.
- **`domain-model.md`** §3 (`TenancyCommenced` payload = `property_ref`), §4
  (independence-finding amendment), and §10 (reference-only PII posture adopted for
  tenant identity; Property Balance parked) updated.
- **Spec D6** records the no-PII-on-log invariant as the public-route control.

## Considered options

- *Property as a full aggregate now* — rejected: no money invariant today, so it
  would be an invariant-free aggregate. The stateful thing is the Property Balance,
  which is deferred.
- *The owner balance grows the `Tenancy` or `Property` aggregate* — rejected: it's
  a distinct, property-keyed balance that spans tenancies (a management-engagement
  concern, not one tenant's rent and not the bricks), so it earns its own aggregate.
- *Tenant names frozen on the event (evidence-grade)* — rejected: the log is
  immutable **and** public (D6), so real-looking PII in it is a liability that can't
  be undone; for synthetic data the disposable Directory gives display identity
  without that cost, and `property_ref` (non-PII) still carries the structural
  identity that recurs across re-lets.
- *Tenant as a `Party` entity* — deferred: over-modeling for a learning sim with no
  cross-tenancy party invariant.
