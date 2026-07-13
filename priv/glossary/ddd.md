# Domain-Driven Design patterns

The strategic and tactical DDD patterns Latchkey uses. Each entry names the concept,
the **code symbol** it maps to, the **live** inspector surface where you can watch it
run, and a link to its **source**. Concepts with no code symbol and no live surface are
listed under [More DDD concepts](#more-ddd-concepts) as links out, never as faked entries.

## Aggregate

The consistency boundary that owns a stream's invariants and decides which new events
may be appended. Latchkey's one aggregate is the **Tenancy**: a pure core that folds a
tenancy's own events into a `State` (`evolve/2`) and validates each command against that
state (`decide_*/2`). Every stream is one aggregate instance, id `tenancy-<slug>`.

**Symbol** `Latchkey.PropertyManagement.Tenancy` · **Live** [aggregate-state pane on a deep stream →](/inspector/streams/tenancy-notice-then-paid#aggregate-state-pane) · **Source** [`tenancy.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/tenancy.ex)

## Bounded context

A boundary inside which a model and its language are consistent. Latchkey has two
modelled contexts: the **deep** Tenancy & Arrears context (a full write model, read
model and ledger) and the **edge** Accounts context (append-only payment facts, no
aggregate). The orientation map draws both, plus the named-only contexts that are
deliberately *not* modelled.

**Symbol** `Latchkey.PropertyManagement` (deep) · `Latchkey.Accounts` (edge) · **Live** [orientation map →](/inspector) · **Source** [`property_management/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management)

## Anti-corruption layer

A seam that translates one context's language into another's so an upstream model can't
leak into a downstream one. Latchkey's **ACL-1** turns an Accounts `PaymentReceived`
(edge fact) into a Tenancy `RentPaymentRecorded` (an arrears-reducing PM event) —
idempotently, keyed on `source_payment_id`. It is the arrow on the map labelled
"payment → arrears reduction".

**Symbol** `Latchkey.PropertyManagement.PaymentAcl` · **Live** [ACL-1 seam on the map →](/inspector) · [the Accounts edge stream →](/inspector/streams/accounts) · **Source** [`payment_acl.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/payment_acl.ex)

## Domain event

A named fact that already happened, recorded in the past tense and never mutated. These
*are* the write model — `TenancyCommenced`, `RentFellDue`, `RentPaymentRecorded`,
`TerminationNoticeGiven`, `KeysReturned`, `TenancySettled`. Every PM event carries the
bitemporal envelope (`occurred_on` / `recorded_on`).

**Symbol** `Latchkey.PropertyManagement.Tenancy.Events.*` · **Live** [event-log pane on a deep stream →](/inspector/streams/tenancy-notice-then-paid#event-log) · **Source** [`tenancy/events/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/events)

## Command

A *request* to change state — an intent, not a fact. Commands (`CommenceTenancy`,
`RecordPayment`, `GiveTerminationNotice`, …) are validated by the aggregate, which may
reject them or emit events; unlike events they are never stored. The inspector is
strictly read-only, so it issues no commands and has no command pane — this concept
degrades to symbol + source (per the spec's anchor tripwire).

**Symbol** `Latchkey.PropertyManagement.Tenancy.Commands.*` · **Source** [`tenancy/commands/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/commands)

## Ubiquitous language

The shared, precise vocabulary the code, docs and this glossary all speak — "rental
ledger", "vacant possession", "days behind". It lives in one file, `CONTEXT.md`, which
the glossary's domain lens renders verbatim so the two can never drift.

**Symbol** `CONTEXT.md` · **Live** [domain lens →](/inspector/glossary#glossary-domain) · **Source** [`CONTEXT.md` ↗](https://github.com/snag-run/latchkey/blob/main/CONTEXT.md)

## Upstream / downstream

The direction of a dependency between contexts: the **upstream** model shapes the
**downstream** one, never the reverse. Accounts is upstream of Tenancy — payments
originate there and flow down through ACL-1 into arrears — and the ACL exists precisely
so that upstream shape doesn't dictate the downstream Tenancy model.

**Symbol** `Latchkey.PropertyManagement.PaymentAcl` (the directional seam) · **Live** [the ACL-1 arrow on the map →](/inspector) · **Source** [`payment_acl.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/payment_acl.ex)

## Invariant

A rule that must hold for every state the aggregate reaches — e.g. you can't record a
payment against a tenancy that never commenced, or settle one twice. The Tenancy's
`decide_*/2` clauses enforce these before any event is appended; the inspector's
consistency check reconciles the folded state against the live read model to show they
agree.

**Symbol** `Latchkey.PropertyManagement.Tenancy` `decide_*/2` · **Live** [consistency check on a deep stream →](/inspector/streams/tenancy-notice-then-paid#consistency-check) · **Source** [`tenancy.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/tenancy.ex)

## More DDD concepts

Concepts without a dedicated code symbol or live surface — links to the canonical docs
rather than a faked in-app entry:

- **Entity · value object** — [domain-model.md ↗](https://github.com/snag-run/latchkey/blob/main/docs/domain-model.md)
- **Context map (upstream/downstream, the whole picture)** — [context-map.md ↗](https://github.com/snag-run/latchkey/blob/main/docs/context-map.md)
