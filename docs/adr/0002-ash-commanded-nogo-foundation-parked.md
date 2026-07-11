# 0002 — AshCommanded v0.2.0 rejected; foundation parked

Status: accepted — amends [ADR 0001](0001-domain-first-ash-native-es.md), which is now **on hold**

ADR 0001 chose **AshCommanded** on the strength of its README, which reads as
declarative fold-as-truth CQRS/ES. Before building the domain on it, a **go/no-go
smoke test** (2026-07-10) read the actually-generated code in `deps/ash_commanded`
rather than the docs. It does **not** event-source, and the mismatch is
**structural, not a bug** — so AshCommanded v0.2.0 is **rejected** and the
event-sourcing foundation is **parked** pending the follow-up below.

## Finding (from source, not the README)

AshCommanded is built on the equation **command = Ash action**. Executing a command
*is* running a CRUD action on the resource; the event is a *record* of that action.
That is **action-sourcing**, not aggregate event-sourcing. Evidence:

- `generate_aggregate_module.ex` — the aggregate's `execute/2` calls
  `CommandActionMapper.map_to_action/…` (an `Ash.create`/`update` — a real DB write)
  and returns the event as a **byproduct**. It never folds state to *decide*.
- `command_action_mapper.ex` — `:create → execute_create → Ash.create`.
- `generate_projector_modules.ex` — the projector runs an action on the **same**
  resource, so the resource is simultaneously write- **and** read-model
  (double-write; PK collision on the documented `:create` path).
- There is **no `apply/2`-fold feeding a decision**, so there is **nowhere to
  enforce a write-side invariant from folded state** — **L2 and the L7 arrears gate
  cannot be expressed.** Enforcing invariants from the fold *is this project's
  thesis*.
- Aggregate/projector/router/handler modules are **skipped in `:test`** by default,
  so the specified seam can't even run without undocumented overrides.

This is the **AshEvents-style current-state model** ADR 0001 explicitly rejected —
just less mature. ADR 0001's headline claim ("AshCommanded realises the model ~1:1")
is therefore **false**, and is retained there only as historical context.

## Decision

- **Reject AshCommanded v0.2.0.** Do not build the domain on it.
- **Park the foundation.** ADR 0001 goes **on hold**; do not treat AshCommanded as
  the chosen foundation, and do not merge that claim into the domain as-is.

## Options for when unparked (recorded, not yet chosen)

1. **Raw Commanded + Ash read models** *(leaning)* — hand-write Commanded aggregates
   / router / app (pure `execute`, `apply` folds, real state invariants); Ash for
   read-model projections only. Genuine fold-as-truth; ADR 0001's mapping table
   holds for *raw* Commanded, and Commanded's process managers fit the §8 ACLs and
   §10 sagas. Would supersede ADR 0001.
2. **Events-as-resources (pure Ash)** — ADR 0001's already-considered fallback:
   model an event log + manual fold in Ash, no Commanded. Stays in the fluent tool;
   owns the ES machinery (and the ACL/saga coordination) by hand.

`AshStateMachine` (mutates status in place) and `AshEvents` (current-state + audit
log) remain rejected.

## Open follow-up

Investigate AshCommanded's internals and possibly pursue an **upstream OSS
contribution** adding true fold-as-truth aggregate support (the
`skip_aggregate_module_creation` escape hatch is a candidate seam). Gauge maintainer
receptiveness via a GitHub issue/discussion **before** building a PR — the gap may be
by-design.

## Process note

The smoke test earned its keep: it caught a structural mismatch **before** any domain
code was written, by reading generated source instead of trusting a v0.2.0 README.
