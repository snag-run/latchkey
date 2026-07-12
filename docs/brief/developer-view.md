# Brief: Developer view — an event-sourcing / DDD "how it's built" view, separate from the Property Manager view

## Problem

Latchkey applies a stack of DDD + event-sourcing concepts — bounded contexts,
aggregates, events, commands, projectors, ACLs, the payments seam — but they
currently live in two places only: **prose docs** (`docs/context-map.md`,
`docs/domain-model.md`) and **running code** (the `Tenancy` aggregate, its
events, `ArrearsProjector`). Neither makes the concepts *concrete and connected*:
the prose describes the model in the abstract; the code runs but is invisible
unless you read Postgres tables or poke `iex`.

Three distinct pains, in priority order:

1. **The builder (David) is new to DDD and wants to consolidate the mental
   model.** Reading the concepts as prose is weaker than seeing them wired to
   real, running events — an actual `TenancyCommenced` folding into actual
   aggregate state. Building the view *is* the consolidation exercise.
2. **The concepts lack living documentation.** The applied concepts should be
   legible as a connected whole ("here is every event, every aggregate, every
   context, and how they relate"), not reconstructed from two long markdown files.
3. **It doubles as a durable portfolio artifact.** David plans to share this at
   work — both to demonstrate what he can build and to serve as a learning
   artifact for colleagues new to DDD/ES.

This is a *pedagogical and demonstrative* problem, not primarily an operational
debugging one. The bar is legibility, correctness of the conceptual story, and
shareable polish — not raw introspection speed.

## Users

- **David (primary).** Purpose: consolidate a DDD/ES mental model by making the
  concepts concrete. Self-validating — building it teaches him regardless of who
  else looks. Teaches: how events fold to aggregate state, where context/aggregate
  boundaries sit, how a read model (projector) differs from the write model.
- **Colleagues at work (secondary).** A learning artifact for others new to
  DDD/ES, and a profile-raising demonstration of David's capability.

## Why Now

**Not now — sequenced after the ES foundation.** Explicitly deferred until:
the ES foundation (issues #37–#44: clock, sweep, Accounts stub, ACL-1,
projector fixes), the **seeder** (seed scenario catalogue), and ideally the
**Oban event generators** (simulated tenant behaviour engine) are in.

Two reasons the ordering matters:

1. The inspector's payoff is showing a *rich* event stream folding across
   contexts (Accounts payments through ACL-1, the sweep emitting `RentFellDue`
   across live tenancies). Today's one-aggregate / four-event system is not yet
   an "ES in action" showcase. Wait for a system worth inspecting.
2. Once the Oban generators emit events over wall-clock time, the inspector is
   *genuinely live* — events land as the simulation runs, not just a static
   replay. The deferral is what makes the "live" story real.

The honest driver is **"the part I want to build once there's a system worth
inspecting"** — excitement + consolidation, not urgency. Nothing breaks if it
slips; it simply isn't the consolidation payoff until the foundation exists.

## Alternatives

- **Do nothing.** The prose docs (`context-map.md`, `domain-model.md`) already
  exist and are grilled. In 3 months nobody external notices; David's model stays
  at "I read the docs." Rejected — the consolidation-by-building is the point.
- **Static diagram only** (Mermaid in the docs / EventCatalog-style export).
  Cheap, shareable, delivers the "see the model as a connected whole" learning.
  **This absorbs the static model-map sub-feature**: a rendered, hand-maintained
  map of one aggregate and four events is just a worse-maintained duplicate of
  `context-map.md`. A Mermaid diagram in the docs covers the at-a-glance need.
- **Full live inspector.** The irreducible thing a diagram *cannot* fake:
  watching a real `TenancyCommenced` land and fold into real `Tenancy` state,
  seeing `ArrearsProjector` rebuild. That "ES in action" moment is the actual
  "consolidate my ES mental model" payoff and the convincing portfolio piece.

**Resolution:** the *live event-stream inspector* is the feature. The *static
model map* is downgraded to a Mermaid diagram maintained in the docs — and the
inspector's own navigation structure (context → aggregate → stream) delivers the
"map" experience populated with live data rather than static boxes.

## Cut-line

A separate **developer route**, distinct from the Property Manager view. The
shape, end to end:

- A live, chronological feed of **every event in the system** with its actual
  stored payload, navigable by the model's own structure: **bounded context →
  aggregate → stream** (e.g. Tenancy & Arrears → `Tenancy` → one tenancy's
  stream). The nav structure *is* the "model map," populated with live data.
- For a selected stream, the ES money-shot side by side: raw **events**, the
  **aggregate state** they fold into, and the **projector read model**
  (`ArrearsProjector`) — so the write-model / read-model distinction is *shown*.
- **Replay (core, not a stretch):** a scrubber over a stream's stored history
  that steps event-by-event and shows aggregate state **rebuilding at each step**
  — rewind to `TenancyCommenced`, step through each `RentFellDue` /
  `RentPaymentRecorded`, watch arrears climb and fall. This is the animated form
  of "events fold to state," and the single most convincing ES interaction.
- Events appear **live** as the simulation (Oban generators) emits them.

**Where scope stops (and why there):**

1. **Read-only. No issuing commands from the view.** Purpose is *showing* ES,
   not operating it. The scrubber's replay delivers the "watch state evolve"
   payoff without a command-input UI, so read-only loses nothing.
2. **Only contexts that actually emit events** (Tenancy & Arrears; Accounts stub
   once #40 lands). The "named-only" contexts (Maintenance, Inspections,
   Compliance, Leasing, BD) belong on the **Mermaid strategic map in the docs**,
   never rendered as empty boxes in the live inspector.
3. **No mutation of the log — shown as a feature.** No editing/deleting events;
   immutability is a core ES lesson the view should make visible.
4. **System-level replay (rebuilding projectors from the store) is out.** That's
   operational infra; the replay here is a read-only pedagogical scrubber only.
5. **Bitemporal (valid-time vs transaction-time) display is a stretch, not v1.**
   Rich once the bitemporal envelope (#38) lands, but v1 must not be gated on it.

## Success Criteria

- **Primary — the consolidation test:** David can open the view, pick a tenancy
  stream, replay it, and explain each step out loud **without notes** — this
  event → folds into this aggregate state → surfaces in this projector read
  model. If it can be taught from the screen, it worked.
- **Artifact test:** every core concept — event, aggregate, stream, bounded
  context, write-vs-read model, immutability — is *visibly represented*, not
  merely implied.
- **Kill / shrink signal:** if building it drifts into UI polish divorced from
  the concepts, or the live/replay adds nothing a static Mermaid diagram already
  gave — shrink back to the diagram and stop.

## Assumptions & Tests

- Assumption: colleagues will engage with this as a learning artifact / it will
  raise David's profile. — Test: show one colleague the existing `domain-model.md`
  or a Mermaid diagram first. **Accepted as risk, not tested** — David is the
  primary user, so the value stands even if the secondary audience never engages.
