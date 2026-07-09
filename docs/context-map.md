# Context Map — Latchkey

> **Orientation only.** This names the subdomains and how they relate — it is
> deliberately **shallow and broad**. The one context modelled *deep* is
> **Tenancy & Arrears** (the payments seam) in [`domain-model.md`](./domain-model.md).
> Everything else here is named to show where it sits, not modelled.
>
> Items marked **(confirm)** are my proposals awaiting your call.

---

## Strategic classification

DDD sorts subdomains by where modelling effort is worth spending:

- **Core** — the differentiator; go deep.
- **Supporting** — necessary, business-specific, not a differentiator; model lightly.
- **Generic** — every business needs it; buy / off-the-shelf; don't model.

---

## The map

### Core domain — Property Management

PM is the **core domain**. It contains several **bounded contexts** (each its own
model + language, even though they're all "PM"):

| Bounded context | Language / concerns | Depth here |
|---|---|---|
| **Tenancy & Arrears** | tenancy, lease terms, rent due, arrears, weeks-behind, notice, overstay; **arrears collections** (notices, NCAT/tribunal, termination) live here | **Deep** — `domain-model.md` |
| **Maintenance / Work Orders** | tenant requests, work orders, tradies, owner approval | Named only |
| **Inspections** | routine inspections, entry/exit condition reports | Named only |
| **Compliance** | smoke alarms, safety checks, bond lodgement, certificates & due dates | Named only |

### Accounts — Trust Accounting  *(supporting subdomain)*

A context in its own right (deep in reality, **stubbed** here to the payment-facts
edge). Owns: receipting, trust ledger, suspense (`UNKNOWN`), reversals,
**invoices** (incl. maintenance/repair bills paid on behalf), disbursement, owner
statements, fees.

### Business Development  *(supporting subdomain)*

Owner-facing origination: landlord onboarding, **management / agency agreements
(BDAs)**, fee structures.

### Leasing / Marketing  *(supporting subdomain — separate from PM)*

Advertising vacancies (incl. **sign boards** and property signage), applications,
screening, approving a tenant, executing the lease — the pipeline that *produces*
a tenancy.

> *Capability, not org chart.* Who physically handles advertising / signboards
> varies by agency — in-house agents, the back-office, or an outsourced vendor
> tee'd up by the office manager — but it's the **same capability**, so it maps to
> the same subdomain. In-house vs outsourced is a *sourcing* detail, below the
> modelling altitude. The map models *what the system does*, not who does it.

### Generic / back-office (buy / off-the-shelf — don't model)

Identity & users · Documents & e-signing · Payment rails / bank feeds ·
Notifications · Reporting / BI · **Office / internal admin** (procuring computers,
stationery, running the office) — real agency work, but *not* part of this
system's domain. A reminder that the map models the *product*, not everything the
business does.

---

## The seams (where the language flips)

The interesting boundaries — a concept in one context becomes a *different*
concept in another:

1. **Accounts → Tenancy & Arrears** — a *payment* becomes an *arrears reduction*.
   **← modelled** (`domain-model.md`).
2. **Maintenance → Accounts** — a *work-order invoice* becomes a *bill paid on
   behalf* → a *disbursement deduction* on the owner statement.
3. **Leasing → Tenancy** — an *approved application + executed lease* becomes
   `TenancyCommenced`.
4. **Business Development → Accounts + Tenancy** — a *signed management agreement*
   sets up the owner + fee structure (→ Accounts) and authorises management (→ PM).
5. **Within PM** — *Inspections → Maintenance* (a defect found becomes a work
   order); *Compliance → Maintenance* (an overdue/failed check triggers
   remediation).

---

## Scope reminder

Only seam **#1** (Accounts ↔ Tenancy & Arrears) is modelled deeply. This map
exists so we know where that seam sits — and which seams (#2–#5) would be the
next interesting ones to model if the project grows.
