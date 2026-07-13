# Domain-Driven Design patterns

The strategic and tactical DDD patterns this codebase uses, each anchored to the
code that embodies it — a symbol, the live inspector surface where you can watch it
run, and its source. The full seed set is authored in #128; the entries below
establish the convention.

## Aggregate

The consistency boundary that owns and validates a stream's invariants. Here the
`Tenancy` aggregate folds its own events and guards the tenancy lifecycle.

- **Symbol:** `Tenancy`
- **Live:** open any `tenancy-…` stream and watch the aggregate-state pane fold.
