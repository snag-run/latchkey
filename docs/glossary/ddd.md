# Domain-Driven Design patterns

New to domain-driven design? Start here. DDD just means building the software around the
real-world domain — here, residential tenancies — and around the exact words people use
to talk about it. Each entry below explains one idea in plain terms first, then points at
the **code symbol** it maps to, the **live** inspector surface where you can watch it run,
and its **source**. A few ideas have no code of their own; those are listed under
[More DDD concepts](#more-ddd-concepts) as links out, never dressed up as fake entries.

## Aggregate

An **aggregate** is the one object put in charge of a single thing's rules — nothing
changes that thing except by going through it. In Latchkey that thing is a **Tenancy**. To
record a payment or give notice you *ask* the Tenancy, and it decides yes or no; it is the
only door in, so the rules can't be side-stepped. It works out its answer by replaying its
own past events in order (a *fold* — see the ES lens), and each Tenancy's history is its
own stream, `tenancy-<slug>`. (The Accounts stream is *not* an aggregate — it only appends
payment facts.)

**Symbol** `Latchkey.PropertyManagement.Tenancy` · **Live** [aggregate-state pane on a deep stream →](/inspector/streams/tenancy-notice-then-paid#aggregate-state-pane) · **Source** [`tenancy.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/tenancy.ex)

## Bounded context

A **bounded context** is a walled-off part of the model where every word means exactly one
thing. Latchkey has two that are actually built: a **deep** one — Tenancy & Arrears, which
does the real work (a write model, a read model, and a ledger) — and a thin **edge** one —
Accounts, which only records that money arrived. Keeping them apart lets "payment" mean one
thing to Accounts and another to Tenancy without the two colliding. The orientation map
draws both, alongside the contexts we name but deliberately don't model.

**Symbol** `Latchkey.PropertyManagement` (deep) · `Latchkey.Accounts` (edge) · **Live** [orientation map →](/inspector) · **Source** [`property_management/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management)

## Anti-corruption layer

An **anti-corruption layer** is a translator sitting between two contexts, so one side's
way of naming things can't leak into the other. Latchkey's is **ACL-1**: when Accounts
says "a payment arrived" (`PaymentReceived`), ACL-1 restates it in Tenancy's language as
"rent was paid — reduce the arrears" (`RentPaymentRecorded`). It also ignores duplicates,
so the same payment arriving twice still only counts once (keyed on `source_payment_id`).
On the map it's the arrow labelled "payment → arrears reduction".

**Symbol** `Latchkey.PropertyManagement.PaymentAcl` · **Live** [ACL-1 seam on the map →](/inspector) · [the Accounts edge stream →](/inspector/streams/accounts) · **Source** [`payment_acl.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/payment_acl.ex)

## Domain event

A **domain event** is a plain record that something happened, written in the past tense and
never changed afterwards — `TenancyCommenced`, `RentFellDue`, `RentPaymentRecorded`, and so
on. In an event-sourced system these records *are* the source of truth: every other view is
worked out from them. Each one carries two dates — when it happened and when the system was
told (see *bitemporality* in the ES lens).

**Symbol** `Latchkey.PropertyManagement.Tenancy.Events.*` · **Live** [event-log pane on a deep stream →](/inspector/streams/tenancy-notice-then-paid#event-log) · **Source** [`tenancy/events/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/events)

## Command

A **command** is a *request* to do something — "commence this tenancy", "record this
payment". It's only an intent: the aggregate checks it and may refuse, and unlike an event
it is never stored (compare *event vs command* in the ES lens). The inspector is read-only
and issues no commands, so there's no live pane for this one — it points straight to the
code instead.

**Symbol** `Latchkey.PropertyManagement.Tenancy.Commands.*` · **Live** none — the inspector is read-only and issues no commands · **Source** [`tenancy/commands/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/commands)

## Ubiquitous language

**Ubiquitous language** is the agreement that everyone — the code, the docs, this glossary,
and you — uses the *same* word for the same thing: "rental ledger", "vacant possession",
"days behind". Latchkey keeps that vocabulary in one file, `CONTEXT.md`, and the glossary's
domain lens shows it as-is — so the words on screen and the words in the code can never
drift apart.

**Symbol** `CONTEXT.md` · **Live** [domain lens →](/inspector/glossary#glossary-domain) · **Source** [`CONTEXT.md` ↗](https://github.com/snag-run/latchkey/blob/main/CONTEXT.md)

## Upstream / downstream

When two contexts depend on each other, the **upstream** one sets the terms and the
**downstream** one has to adapt — never the reverse. In Latchkey, Accounts is upstream of
Tenancy: payments start life in Accounts and flow *down* into arrears. The anti-corruption
layer sits on that boundary precisely so Accounts' shape doesn't get to dictate how Tenancy
models rent.

**Symbol** `Latchkey.PropertyManagement.PaymentAcl` (the directional seam) · **Live** [the ACL-1 arrow on the map →](/inspector) · **Source** [`payment_acl.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/payment_acl.ex)

## Invariant

An **invariant** is a rule that has to stay true no matter what — you can't record a payment
against a tenancy that never started, and you can't settle the same tenancy twice. The
Tenancy aggregate enforces these in its `decide_*/2` checks before it ever appends an event.
The inspector's consistency check is a live proof of it: it folds the events itself and
confirms the answer matches the stored read model.

**Symbol** `Latchkey.PropertyManagement.Tenancy` `decide_*/2` · **Live** [consistency check on a deep stream →](/inspector/streams/tenancy-notice-then-paid#consistency-check) · **Source** [`tenancy.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/tenancy.ex)

## More DDD concepts

Concepts without a dedicated code symbol or live surface — links to the canonical docs
rather than a faked in-app entry:

- **Entity · value object** — [domain-model.md ↗](https://github.com/snag-run/latchkey/blob/main/docs/domain-model.md)
- **Context map (upstream/downstream, the whole picture)** — [context-map.md ↗](https://github.com/snag-run/latchkey/blob/main/docs/context-map.md)
