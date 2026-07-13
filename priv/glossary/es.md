# Event-sourcing patterns

How Latchkey stores state as a log of events and derives everything else from it. Each
entry names the concept, the **code symbol** it maps to, the **live** inspector surface
where you can watch it run, and a link to its **source**. Concepts with no code symbol
and no live surface are listed under [More event-sourcing concepts](#more-event-sourcing-concepts).

## Event store / stream

The append-only source of truth. State is not stored as rows to be updated — it is the
*log* of events, grouped into per-aggregate **streams** (`tenancy-<slug>`, plus the
`accounts` edge stream). Latchkey uses Commanded's Postgres EventStore; the inspector
reads it with `stream_forward/1` and never writes.

**Symbol** `Latchkey.EventStore` · **Live** [full event log →](/inspector/log) · **Source** [`event_store.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/event_store.ex)

## Event vs command

Two different things that are easy to conflate. A **command** is a request that may be
rejected (`RecordPayment`); an **event** is the fact that results and is kept forever
(`RentPaymentRecorded`). Commands are validated by the aggregate and then discarded;
only events are stored. The inspector shows the event side — the command side has no
pane because it issues none.

**Symbol** `…Tenancy.Events.*` vs `…Tenancy.Commands.*` · **Live** [event-log pane →](/inspector/streams/tenancy-notice-then-paid#event-log) · **Source** [`events/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/events) · [`commands/` ↗](https://github.com/snag-run/latchkey/tree/main/lib/latchkey/property_management/tenancy/commands)

## Fold / `evolve`

Turning a list of events into current state by replaying them one at a time through a
pure reducer — `state = Enum.reduce(events, initial, &evolve/2)`. The Tenancy aggregate
folds its own stream this way; the inspector's scrubber re-runs the same fold over any
*prefix* of the log, which is why dragging it reconstructs state at every past moment.

**Symbol** `Latchkey.PropertyManagement.Tenancy.evolve/2` · **Live** [replay scrubber → aggregate-state pane →](/inspector/streams/tenancy-notice-then-paid#replay-scrubber) · **Source** [`tenancy.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/tenancy.ex)

## Projection vs compute-on-read

Two ways to get a read model from the log. A **projection** folds events *ahead of time*
and stores the result — `ArrearsProjector` maintains the `Arrears` read model. **Compute
-on-read** folds the log *on demand* and stores nothing — `Timeline` derives the
double-entry ledger every time it is asked. The inspector shows both against one stream,
and reconciles the projection against a live in-memory fold.

**Symbol** `ArrearsProjector` (projection) vs `Timeline` (compute-on-read) · **Live** [read-model pane →](/inspector/streams/tenancy-notice-then-paid#read-model-pane) · [ledger pane →](/inspector/streams/tenancy-notice-then-paid#ledger-pane) · **Source** [`arrears_projector.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/arrears_projector.ex) · [`timeline.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/timeline.ex)

## Replay

Rebuilding state by folding history again. Because the log is the source of truth, any
derived view can be thrown away and reconstructed by replaying events. The scrubber makes
this tangible: it re-folds prefixes `0..k` through the *same* `ArrearsFold` the operational
projector uses (the shared-fold keystone), so what you replay is exactly what production
computes — never a parallel reimplementation.

**Symbol** `Latchkey.PropertyManagement.ArrearsFold` · **Live** [replay scrubber →](/inspector/streams/tenancy-notice-then-paid#replay-scrubber) · **Source** [`arrears_fold.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/arrears_fold.ex)

## Immutability

Events are only ever appended — never edited or deleted. This is what makes replay and
audit trustworthy: the same log always folds to the same state, and history can't be
quietly rewritten. The inspector enforces it by construction — it offers no edit or
delete affordance anywhere.

**Symbol** `Latchkey.EventStore` (append-only) · **Live** [event-log pane →](/inspector/streams/tenancy-notice-then-paid#event-log) · **Source** [`event_store.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/event_store.ex)

## Bitemporality — `occurred_on` / `recorded_on`

Every fact carries *two* dates: when it happened in the world (`occurred_on`) and when
the system learned it (`recorded_on`). They differ for back-dated or imported facts, and
that gap is real information — arrears are reckoned on `occurred_on`, not on when a
payment was keyed in. The inspector renders both columns and flags divergence.

**Symbol** `Latchkey.Inspector.Resolver.bitemporal/1` · **Live** [bitemporal columns on the event log →](/inspector/streams/tenancy-notice-then-paid#bitemporal-caption) · **Source** [`resolver.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/inspector/resolver.ex)

## Idempotency

Processing the same input twice must have the same effect as once. ACL-1 is idempotent on
`source_payment_id`, so a redelivered `PaymentReceived` never double-reduces arrears — a
must-have for an at-least-once event pipeline. It is cross-cutting, so it has no dedicated
pane; it degrades to symbol + source.

**Symbol** `Latchkey.PropertyManagement.PaymentAcl` (`source_payment_id` guard) · **Source** [`payment_acl.ex` ↗](https://github.com/snag-run/latchkey/blob/main/lib/latchkey/property_management/payment_acl.ex)

## More event-sourcing concepts

Concepts without a dedicated code symbol or live surface — links to the canonical docs:

- **Checkpoint · optimistic concurrency** — [domain-model.md ↗](https://github.com/snag-run/latchkey/blob/main/docs/domain-model.md)
- **Consistency (strong vs eventual)** — [ADR 0003 ↗](https://github.com/snag-run/latchkey/tree/main/docs/adr)
