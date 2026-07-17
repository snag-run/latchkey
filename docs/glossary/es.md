# Event-sourcing patterns

New to event sourcing? The one idea underneath everything here: instead of storing *where
things stand now* and overwriting it as things change, you store *the list of things that
happened* and never change it — then work out "where things stand" by replaying that list.
Each entry explains one piece in plain terms first, then points at the **code symbol**, the
**live** inspector surface where you can watch it run, and its **source**. Ideas with no
code of their own are under [More event-sourcing concepts](#more-event-sourcing-concepts).

## Event store / stream

The **event store** is the append-only log that everything is built from — the single
source of truth for the write model. Nothing is stored as a row you update; instead you
keep the *events*, grouped into **streams** (one per Tenancy, `tenancy-<slug>`, plus the
`accounts` edge stream). Views you read from often — like the Arrears **read model** — are
stored separately and rebuilt from the log whenever needed. Latchkey uses Commanded's
Postgres event store; the inspector only ever reads it.

**Symbol** `Latchkey.EventStore` · **Live** [full event log →](/inspector/log) · **Source** [`event_store.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/event_store.ex)

## Event vs command

These two are easy to mix up. A **command** is a *request* that can be turned down —
"record this payment" (`RecordPayment`). An **event** is what's left once it's accepted: the
settled fact, kept forever — "rent was paid" (`RentPaymentRecorded`). Commands are checked
and then thrown away; only events are stored. The inspector shows the event side of that
line — there's no command side to show, because it never issues any.

**Symbol** `…Tenancy.Events.*` vs `…Tenancy.Commands.*` · **Live** [event-log pane →](/inspector/streams/tenancy-notice-then-paid#event-log) · **Source** [`events/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/events) · [`commands/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/commands)

## Fold / `evolve`

A **fold** is how you turn a list of events back into current state: start from nothing and
apply them one at a time, each event nudging the state forward — exactly what
`Enum.reduce(events, initial, fn event, state -> evolve(state, event) end)` does. The
Tenancy aggregate folds its own stream this way to know where a tenancy stands. The
inspector's scrubber does the same fold over just the *first few* events, which is why
dragging it rebuilds the tenancy as it looked at any past moment.

**Symbol** `Latchkey.PropertyManagement.Tenancy.evolve/2` · **Live** [replay scrubber → aggregate-state pane →](/inspector/streams/tenancy-notice-then-paid#replay-scrubber) · **Source** [`tenancy.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/tenancy.ex)

## Projection vs compute-on-read

Once state lives in a log, there are two ways to answer a question about it. A
**projection** folds the events *ahead of time* and saves the answer, so reads are cheap —
`ArrearsProjector` keeps the `Arrears` read model up to date this way. **Compute-on-read**
skips the saving: it folds the log *on the spot*, every time you ask, and stores nothing —
`Timeline` builds the double-entry ledger like this. The inspector shows both against one
tenancy, and even checks the saved projection against a fresh fold to prove they agree.

**Symbol** `ArrearsProjector` (projection) vs `Timeline` (compute-on-read) · **Live** [read-model pane →](/inspector/streams/tenancy-notice-then-paid#read-model-pane) · [ledger pane →](/inspector/streams/tenancy-notice-then-paid#ledger-pane) · **Source** [`arrears_projector.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/arrears_projector.ex) · [`timeline.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/timeline.ex)

## Replay

**Replay** is rebuilding state by folding history over again. Because the log is the source
of truth, any derived view can be thrown away and reconstructed at any time — nothing is
lost. The scrubber makes this concrete: it re-folds the first `k` events through the *same*
`ArrearsFold` the real projector uses, so what you watch on screen is exactly what
production computes — not a look-alike written just for the demo.

**Symbol** `Latchkey.PropertyManagement.ArrearsFold` · **Live** [replay scrubber →](/inspector/streams/tenancy-notice-then-paid#replay-scrubber) · **Source** [`arrears_fold.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/arrears_fold.ex)

## Immutability

**Immutable** means the events are only ever added to — never edited, never deleted. That's
what makes replay and audit trustworthy: the same log always folds to the same state, and
no one can quietly rewrite what happened. The inspector honours this by design — nowhere
does it offer a way to edit or delete anything.

**Symbol** `Latchkey.EventStore` (append-only) · **Live** [event-log pane →](/inspector/streams/tenancy-notice-then-paid#event-log) · **Source** [`event_store.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/event_store.ex)

## Bitemporality — `occurred_on` / `recorded_on`

**Bitemporal** just means every fact carries *two* dates: when it happened out in the world
(`occurred_on`) and when the system found out (`recorded_on`). Usually they match, but for a
back-dated or imported fact they don't — and that gap is real information. It's why arrears
are counted from when rent actually fell due, not from when someone got around to keying it
in. The inspector shows both dates side by side and flags the rows where they differ.

**Symbol** `Latchkey.Inspector.Resolver.bitemporal/1` · **Live** [bitemporal columns on the event log →](/inspector/streams/tenancy-notice-then-paid#bitemporal-caption) · **Source** [`resolver.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/inspector/resolver.ex)

## Idempotency

**Idempotent** means doing something twice lands you in the same place as doing it once.
Event systems deliver a message *at least* once, so the same `PaymentReceived` can turn up
twice — ACL-1 guards against that with the payment's `source_payment_id`, so a repeat never
reduces the arrears a second time. This is a cross-cutting safeguard rather than a screen,
so it points to the code rather than a live pane.

**Symbol** `Latchkey.PropertyManagement.PaymentAcl` (`source_payment_id` guard) · **Live** none — cross-cutting guard, no dedicated pane · **Source** [`payment_acl.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/payment_acl.ex)

## More event-sourcing concepts

Concepts without a dedicated code symbol or live surface — links to the canonical docs:

- **Snapshot** — a saved fold you resume from, so replay reads only the recent tail instead of the whole stream. **Deliberately not built here:** replay cost is a function of stream *length* (event rate × lifespan), and rent is low-rate — even a decades-long tenancy stays in the low thousands of events, so no stream ever grows long enough to need one (gated on fold-on-read latency) — [ADR 0006 §6 ↗](https://github.com/snag-run/latchkey/blob/main/docs/adr/0006-tenancy-timeline-read-model.md)
- **Checkpoint · optimistic concurrency** — [domain-model.md ↗](https://github.com/snag-run/latchkey/blob/main/docs/domain-model.md)
- **Consistency (strong vs eventual)** — [ADR 0003 ↗](https://github.com/snag-run/latchkey/tree/main/docs/adr)
