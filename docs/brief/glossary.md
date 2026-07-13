# Brief: Glossary — an in-app, curated on-ramp to the domain and to DDD/ES, anchored to this codebase

## Problem

Latchkey is a learning project, and understanding has **lagged the code**.
Agent-augmented implementation moved faster than the builder (David) could
internalise, so the concepts the code applies — aggregates, projections, ACLs,
bitemporality, plus the domain's own language (arrears, `property_ref`, re-let,
vacant possession) — are shipped but not fully consolidated in David's head.

The pain is **not** a blocked-lookup pain: nobody is stuck unable to find a
definition (Fowler, Vernon, and every ES blog define the general concepts; the
domain terms are in `CONTEXT.md`). The pain is that there is **no accessible,
curated on-ramp** that (a) consolidates David's own understanding and (b) lets a
newcomer — a colleague, a build-in-public reader — orient to *both* the domain
being modelled *and* the DDD/ES concepts, in one place, without a book and
without reading two long markdown files on GitHub.

The scarce thing Latchkey is uniquely positioned to provide is **anchoring**:
the mapping from a concept to *this* codebase — "aggregate → `Tenancy`",
"projection → `ArrearsProjector`", "ACL → `PaymentACL`". A generic definition is
commodity; the same definition *wired to the running code the reader is looking
at* is the learning artifact. Any general DDD/ES definition earns its place only
as **curated + anchored** scaffolding, never as a re-typed encyclopedia entry.

## Users

- **David (primary).** Consolidate understanding that lagged agent-speed
  implementation. Onboard himself to the domain model and to the DDD/ES concepts
  the code already uses.
- **Colleagues + build-in-public audience (secondary).** An accessible learning
  artifact — accessibility of the on-ramp is an explicit goal, not a bonus.

**What it teaches the builder — and the forcing function.** David is new to
DDD/ES and the concepts are still fuzzy, so this is real learning, not
transcription. The consolidation does *not* come from writing one-line
definitions (that can be faked); it comes from the **anchoring** step — being
forced, term by term, to point at the exact symbol/line in the repo each concept
maps to. If a concept can't be located in the code, that surfaces a real gap in
understanding. The definitions serve the audience; the anchoring serves David.
An **active-recall** presentation (e.g. question → reveal) would add a second
forcing function for both audiences — recall beats re-reading for durability.
*The specific format is a `grill-spec` decision, not a why-level one — noted so
it isn't lost.*

## Alternatives

- **Do nothing.** `CONTEXT.md`, `domain-model.md`, and the live inspector all
  exist. **Rejected** — do-nothing is a real barrier to onboarding: a colleague
  or build-in-public reader lands on the inspector and sees `Tenancy` /
  `ArrearsProjector` / `PaymentACL` with no on-ramp explaining what an aggregate
  / projector / ACL even is. That makes the whole project weaker *as a
  portfolio artifact*, which is the explicit secondary goal.
- **Markdown-only glossary** (`docs/glossary.md` or a `CONTEXT.md` section).
  This is the null hypothesis — cheap, and it can carry definitions + anchoring
  text. **Rejected for the accessibility/portfolio reason:** a person you're
  showing the project to lands on the *app*, not on GitHub docs. The on-ramp has
  to live in the shared artifact itself to do its job.
- **Link out to canonical sources only** (Fowler, Vernon, ES blogs). Always
  better-written than anything we'd type, zero-maintenance — but maximum
  context-switch and never about *this* codebase. **Adopted as a component, not
  the whole:** cite canonical sources *and* give a brief in-app summary, so a
  reader is oriented in-context and can go deeper if they want.

**Resolution:** an **in-app** learning aid — brief, curated summaries anchored to
this codebase, linking out to canonical sources for depth. It beats the markdown
file on accessibility (portfolio audience) and beats link-out-only on anchoring
and low context-switch.

## Cut-line

A **docs-flavoured extension of the inspector** — reference content that lives on
the inspector surface, distinct in nature from the inspector's live/interactive
replay panes. Each entry is one thin, uniform unit:

> **term → one-paragraph plain-language summary → anchor to *this* codebase (the
> symbol / pane it maps to) → link out to a canonical source for depth.**

Covering all **three lenses** from the issue — domain-context, DDD patterns, ES
patterns — because the onboarding audience needs all three and the brief-summary
format keeps each cheap. Its home is the inspector (a browsable glossary index,
with anchor hooks so live terms can link into it); it is *not* a separate feature
divorced from the inspector.

**Where scope stops, and why there:**

1. **Every entry anchors to something real** — a domain term in `CONTEXT.md`, or
   a DDD/ES concept *actually applied in the code* (aggregate → `Tenancy`,
   projection → `ArrearsProjector`, ACL → `PaymentACL`, bitemporality →
   `occurred_on` / `recorded_on`). **A concept neither in the domain nor in the
   code gets no entry.** This tripwire stops the glossary sprawling into "teach
   all of DDD" — un-anchored theory is what the canonical links are for. (One
   notch out = a generic DDD encyclopedia, rejected as commodity + unmaintainable
   duplicate of the internet; one notch in = domain-terms-only, rejected because
   the audience needs the DDD/ES concepts too.)
2. **Brief summaries, not worked tutorials.** One paragraph + the code anchor
   *is* the worked example. No multi-step lessons per term — the inspector's
   replay already carries the deep "watch it happen" story; this is orientation.
3. **No re-writing canonical theory.** Summarize and link; don't try to
   out-explain Fowler/Vernon. Guards against duplicating (and having to maintain)
   the internet.

## Why Now

No urgency; nothing breaks if it slips. But *now* is reasonable, not arbitrary,
and the usual "wait for a richer system" counter-argument **dissolves** here:

- **The surface exists now.** The inspector is live, so the glossary finally has
  a home to attach to (in-app, anchored to visible code). It wasn't
  buildable-as-intended before the inspector landed.
- **The understanding gap is active now.** Consolidation value decays as more
  unconsolidated concepts pile up; anchoring the settled set now is easier than
  chasing a moving target.
- **It's a living, extensible artifact, and non-blocking.** Because it grows as
  Accounts/payments land (rather than being a one-shot pass), there's no need to
  choose between "now" and "wait for a richer system" — start with the settled
  Tenancy/Arrears/ACL concepts and extend later. And glossary work doesn't block
  the main build, so pulling it forward costs nothing on the critical path.

## Success Criteria

- **Primary — did David learn (self-gaugeable).** The honest measure is whether
  David comes away understanding the concepts better: for every entry he can
  point at the exact code it anchors to and explain the concept out loud without
  notes. The forcing function is in the building — a term he can't anchor while
  writing it has *found a real gap*, which is the feature working.
- **Secondary — onboarding (only measurable by asking).** This one is **not
  self-assessable**: the only real gauge is asking readers (a colleague, a
  build-in-public reader) whether it was hard to understand, and whether they can
  say what each concept is *and where it lives in this codebase* without David
  explaining it. If we don't ask, we don't know it worked.
- **Kill / shrink signal.** If entries drift into re-writing canonical theory (an
  un-anchored encyclopedia), or the summaries add nothing a bare Fowler link
  already gives — shrink back to: surface `CONTEXT.md` in-app + link out, and
  drop the curated summaries. The summaries earn their place only through the
  anchoring-to-this-codebase.

## Assumptions & Tests

- Assumption: the in-app, anchored glossary actually lowers the onboarding
  barrier for someone new to DDD/ES (vs. bouncing off the inspector, or reading
  canonical sources alone). This is the load-bearing empirical belief and it is
  **not** resolvable by reasoning. — Test: show one colleague new to DDD/ES the
  inspector + glossary and ask, unprompted, what an aggregate / projection / ACL
  is and where it lives; note where they get stuck. Cheap, and it converts the
  secondary criterion from hypothesis to evidence.
- Assumption: colleagues / a public audience engage with the artifact at all.
  Carried as **accepted risk** (as in the developer-view brief) — David is the
  primary user, so the consolidation value stands even if the secondary audience
  never shows up.

## Out of Scope

- **Active-recall / Q&A presentation format** — a promising way to add a second
  forcing function (recall beats re-reading), but *how* the glossary is presented
  is a `grill-spec` decision, not why-level. Noted so it isn't lost.
- **Route / placement decision** (standalone glossary index vs. purely inline
  enrichment of live inspector terms) — settled at brief level only as "an
  extension of the inspector"; the exact surface is a `grill-spec` call.
