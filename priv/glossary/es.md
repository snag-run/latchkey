# Event-sourcing patterns

The event-sourcing patterns behind the inspector — the append-only log, folding
events into state, and replaying history — each anchored to a symbol and to the
live surface where you can watch it happen. The full seed set is authored in #128;
the entry below establishes the convention.

## Projection vs compute-on-read

State can be **maintained** by a projector writing a read model, or **computed on
read** by folding the log on demand. The inspector shows both against one stream.

- **Symbol:** `ArrearsProjector`
- **Live:** the read-model pane on any deep stream shows the projected state.
