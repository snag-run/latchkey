# Spec: Glossary — an in-app, markdown-rendered on-ramp to the domain and DDD/ES, completing the inspector's teaching layer

> Why-context: `docs/brief/glossary.md` (issue #122). This spec owns the *how*.

## Problem Statement

Drawn from the brief: understanding lagged agent-speed implementation, and there
is no accessible in-app on-ramp to *both* the domain being modelled *and* the
DDD/ES concepts the code uses. The scarce value is **anchoring** — concept → *this*
codebase — not commodity definitions. Today the inspector already teaches inline
(per-pane `caption` + `read_more`), but every `read_more` link leaves the app to
GitHub, and there is no consolidated place to browse the terms.

## Solution

Complete the teaching layer the inspector already has: give its definitions an
**in-app** home and a browsable index, covering three lenses (domain-context, DDD
patterns, ES patterns). Content is **markdown, rendered in-app**; the domain lens
renders `CONTEXT.md` itself (single source, always in sync), the DDD and ES
lenses are new authored markdown. The existing external `read_more` links are
redirected to these in-app targets.

The same in-app machinery then extends to the two **deep docs** — the strategic
`context-map.md` and the tactical `domain-model.md` — which render on their own
routes as a coexisting reference library (D8–D11, issue #131), so the `read_more`
links land on the exact deep-doc section in-app rather than leaving for GitHub.

## User Stories

1. As David (still learning DDD/ES), I want to open an in-app glossary and see
   each concept named against the exact code it maps to, so that my understanding
   catches up to what was implemented.
2. As a colleague new to DDD/ES, I want a single in-app page that defines the
   domain terms and the DDD/ES concepts, so that I can orient without a book or
   reading GitHub markdown.
3. As a reader in the inspector, I want a term's "read more" to open an in-app
   definition, so that I don't leave the app to GitHub to understand what I'm
   looking at.
4. As a reader of a DDD/ES entry, I want a link to the *live* inspector surface
   where the concept runs (and an octocat link to its source), so that I can see
   the concept in action and read its implementation.
5. As a visitor landing on the inspector, I want the orientation map to point me
   to the glossary, so that the on-ramp is discoverable.
6. As a maintainer, I want the domain lens to render `CONTEXT.md` directly, so
   that the glossary never drifts from the ubiquitous language.

## Implementation Decisions

### D1 — Content model: markdown rendered in-app (KEYSTONE)

Glossary content is **markdown, rendered in-app**, not structured data records.
Per-lens source of truth:

- **Domain lens → `CONTEXT.md` itself**, rendered in-app. Not copied — single
  source of truth, always in sync, zero duplication. Per-term deep links use its
  `##` heading anchors.
- **DDD lens + ES lens → new authored markdown** (one home in the repo), rendered
  by the same interpreter.

*Consequence accepted with eyes open:* freeform markdown makes a later
active-recall/Q&A format and a structured cross-lens search index harder (those
want per-term data). Active-recall is already deferred (brief Out of Scope), so
this is acceptable now; revisit only if that need becomes real.

### D2 — Render in-app (add a markdown renderer), do not link out

Render the markdown **in-app**; do not settle for linking to `CONTEXT.md` on
GitHub. Forced by two facts: (a) the brief's core accessibility thesis rejects
sending a portfolio visitor out to GitHub, and (b) the DDD/ES lenses are new
authored content that must render *somewhere* in-app regardless — so the renderer
is being added anyway, and the domain lens rendering `CONTEXT.md` then comes free.
A markdown renderer dependency is added (specific library is a ticket-level
detail; content is trusted first-party markdown, so sanitisation is not a driver).

### D3 — Placement: a dedicated `/inspector/glossary` route, advertised from the top-bar

A dedicated **`/inspector/glossary`** route — a `:glossary` live action on
`InspectorLive`, added **inside the existing `live_session :inspector`** (not a
standalone route, so the inspector's session contract is preserved) — renders the
three lens-sections on one scannable page — domain
(from `CONTEXT.md`), DDD, ES — each **term a heading with a fragment anchor** for
deep-linking. The **persistent top-bar advertises it** with an entry-point link on
every view (**#140** — promoted from the original landing-only "Reference /
Glossary" pill). Rejected: folding the glossary into the landing —
three lenses of terms bloat the orientation map and make per-term deep-linking
awkward.

### D4 — Redirect the existing `read_more` links in-app — **SUPERSEDED by D10**

> **Superseded** (issue #131 grill, 2026-07-14). D4 proposed redirecting the
> `read_more` links to `/inspector/glossary#term`. Once the *deep docs*
> themselves render in-app (D8), the faithful target is the deep-doc section the
> pane already references — no lossy concept→glossary-term remap. See **D10**.
> The original text is retained below for provenance only; it is superseded and
> non-normative — implementers follow D10, not this.

The five per-pane `read_more` links (currently pointing out to GitHub
`domain-model.md` / `context-map.md` anchors) are **redirected to
`/inspector/glossary#term`**. This closes the brief's actual gap — definitions
stop leaving the app — and makes the inline teaching layer and the browsable
index share one in-app destination.

### D5 — Anchor mechanics for DDD/ES entries (a + b + c)

Every authored DDD/ES entry carries **each applicable anchor**, and always at
least one of (a) or (b) — most carry all three:

- **(a) Symbol name** — e.g. aggregate → `Tenancy`, projection → `ArrearsProjector`,
  ACL → `PaymentACL`. The floor; mirrors the existing captions.
- **(b) Live inspector surface** — a link to where the concept is *shown running*
  (e.g. the Arrears read-model pane). Bidirectional with the redirected
  `read_more` (pane ↔ glossary). This is the anchoring payoff — the concept seen
  live, which docs can't fake.
- **(c) Source on GitHub** — an octocat badge linking the symbol to its source.
  Leaving-the-app for *source* is acceptable in a way it wasn't for definitions.
  Optional: omitted when no single source symbol exists (e.g. cross-cutting
  concepts like idempotency).

**Tripwire made checkable (from the brief):** an entry with neither (a) nor (b)
does not ship. A few concepts have no dedicated live pane (command — read-only,
no command UI; idempotency; replay maps to the scrubber): they degrade to (a)
symbol-name (and (c) where a single source symbol exists), which still satisfies
the floor.

### D6 — Render `CONTEXT.md` as-is, with a framing caption

The domain lens renders `CONTEXT.md` **verbatim** — its inward cross-references
("issue #5", "domain-model.md §7", "ADR 0008") are left intact. Rewriting them
for an outside reader, or resolving them at render time, would be annoying to
maintain and drift over time; keeping the single source untouched is worth the
dangling refs. A short **in-app intro caption** wraps the domain-lens page to set
expectations ("Latchkey's ubiquitous language; cross-refs point to the ADRs and
domain model"). The domain lens is the *reference* lens (look up a term seen in
the inspector); the DDD/ES lenses carry cold-onboarding.

### D7 — Content scope: inclusion rule + seed set, enumeration left to authoring

The spec pins the **rule** and a **confirmed seed set**; the exhaustive term list
is authoring work (kept out of the spec to avoid staleness).

**Inclusion rule (strict tripwire):** a term earns a full anchored entry only if
it has (a) a code symbol or (b) a live inspector surface (DDD/ES), or it is a term
in `CONTEXT.md` (domain). A general concept with **no** anchor is
**canonical-link-only** — never a faked anchored entry — even if that leaves an
onboarding gap. Un-anchored theory is what the canonical links are for.

**Confirmed-anchored seed set:**
- *DDD:* aggregate (`Tenancy`), bounded context (deep/edge), anti-corruption
  layer (`PaymentACL` / ACL-1 seam), domain event (event log), command (symbol
  only — read-only, no pane), ubiquitous language (`CONTEXT.md`),
  upstream/downstream (context map).
- *ES:* event store / stream, event-vs-command, fold/`evolve` (fold panes +
  scrubber), projection vs compute-on-read (`ArrearsProjector`), replay
  (scrubber), immutability (event-log note), bitemporality —
  `occurred_on`/`recorded_on`.

**Verify-or-drop at authoring** (anchor uncertain → canonical-link-only):
entity/value object, invariant, checkpoint, idempotency, optimistic concurrency,
compute-on-read's `Timeline` example (may not be built yet).

### D8 — Render the deep docs in-app as a distinct, coexisting docs surface (issue #131)

The two canonical **deep docs** — `docs/context-map.md` (strategic) and
`docs/domain-model.md` (tactical, §1–§11) — render **in-app**, each on its own
route: **`/inspector/docs/context-map`** and **`/inspector/docs/domain-model`**
(live actions inside the existing `live_session :inspector`, mirroring D3). They
reuse the #127 machinery unchanged — the same compile-time `@external_resource` +
`MDEx.to_html!` + `header_id_prefix: ""` anchor scheme as `LatchkeyWeb.Inspector.Glossary`.

**Not a reversal of D2/D5/D6 — a scope expansion.** #131's framing ("reverses
D2/D5/D6") was imprecise. D2 (render in-app) is the *precedent this extends* to
two more docs; D5(c) (source code → GitHub octocat) stands untouched — the deep
docs are learning *prose*, not source code; D6 (verbatim render) is extended, not
undone (D9). What actually moves is one implicit scoping assumption — *"only
`CONTEXT.md` + the authored DDD/ES lenses render in-app; the deep docs stay
GitHub-only."* The deep docs were mis-filed as "leaving-for-source is acceptable"
(D5(c)); they are prose-to-learn, so they belong in-app.

**Distinct surface, not folded into the glossary page.** The glossary is the
concise *index / on-ramp* (look up a term seen in a pane); the deep docs are a
*read-through reference library*. They **coexist** — the `CONTEXT.md` domain lens
(concise ubiquitous language) and `domain-model.md` (deep prose) serve different
reading modes (30-second look-up vs. sit-and-read) and **neither absorbs the
other**. Folding the deep docs inline was rejected: `domain-model.md` alone is
§1–§11 and would wreck the glossary's one-page scannability that D3 protects.

### D9 — Deep-doc link handling: verbatim text refs; relative markdown links rewritten to GitHub (Option A)

The deep docs render **verbatim** (extends D6) **except** for one class of link
that would break in-app. Two cases:

- **Plain-text refs** (`§7`, `ADR 0008`, `#16`) — render as inert text, never
  break. **Kept verbatim.** (`CONTEXT.md` has *only* this kind, which is why
  D6-verbatim renders correctly today.)
- **Relative markdown links** (`[ADR 0005](adr/0005-…md)` ×5 in `domain-model.md`;
  `[domain-model.md](./domain-model.md)` in `context-map.md`) — rendered in-app at
  `/inspector/docs/…`, a relative `href` resolves to `/inspector/docs/adr/…` →
  **404**. So verbatim is *not* neutral here: it ships broken links. **Fix
  (Option A):** a single render-time rule rewrites any *relative* `href` to its
  absolute GitHub `blob/main/docs/…` URL; **absolute URLs** (e.g. the NSW RTA
  links), **`#` anchors**, and **plain-text refs** are untouched.

Option A is one *mechanical* rule (not per-ref hand-editing — honors D6's
"don't hand-resolve, don't drift"), keeps the source markdown unmodified, and is
consistent with D5(c): ADRs and canonical docs *not* in the in-app set are
legitimate GitHub link-outs. **Deferred (gated):** resolving cross-doc links
between the two in-app docs to `/inspector/docs/…` instead of GitHub (Option B) —
trigger: the GitHub round-trip for an already-in-app doc proves annoying.
Auto-linking plain-text `§`-refs to same-page anchors — trigger: reader feedback
shows the manual scroll is real friction.

### D10 — `read_more` retarget: existing deep-doc anchors, in-app, same-tab (supersedes D4)

The seven pane `read_more` links **keep the exact deep-doc section anchors they
already carry** — they were authored forward-compatibly and already equal the
slugs MDEx emits in-app (`#3-events-producers`, `#4-the-tenancy-aggregate`,
`#7-arrears`; the orientation-map link points at the context-map page top). The
retarget is therefore **two mechanical edits, no anchor changes**:

1. Flip the two base URLs in `inspector_live.ex` (`@docs.domain_model` /
   `@docs.context_map`) from `github.com/…/blob/main/docs/…` to the in-app paths
   `/inspector/docs/domain-model` / `/inspector/docs/context-map`.
2. Render `read_more/1` (`inspector_components.ex`) **same-tab** — drop
   `target="_blank" rel="noopener"` and the `↗` external glyph, use in-app
   navigation. The **octocat/source links stay new-tab external** (separate
   component; D5(c) untouched).

This **supersedes D4**: the target is the deep-doc section the pane already
references (faithful, `domain-model.md §7 → /inspector/docs/domain-model#7-arrears`),
not a lossy concept→`CONTEXT.md`-term remap. The glossary stays reachable for the
*browse* intent via the front doors (D11). **This is issue #129's deliverable** —
issue #129 is reshaped from "redirect to glossary term anchors" to this simpler,
faithful flip, and must land after #131 (the in-app anchors must exist first).

### D11 — Discoverability: two front doors, equal billing (issue #131)

The deep docs get an in-app front door beyond the `read_more` deep-links, so a
browsing visitor who never clicks a specific pane still finds them (the brief's
thesis):

- **Persistent top-bar** (**#140**) — `context map` / `domain model` links beside
  `full log` / `glossary` in `Layouts.inspector`, present on **every** view with
  **equal billing** (no priority ordering between them for now). *Promoted from the
  original landing-map "Reference" pill cluster + docs-page sub-nav, which were
  easily missed and are now removed.*
- **Glossary page** — the domain-lens intro caption ("…cross-refs point to the
  domain model") becomes a **live in-app link** to `/inspector/docs/domain-model`,
  turning a dead reference into a real one.

`read_more`-deep-links-only was rejected: a portfolio visitor who never clicks a
pane would never reach the deep docs, defeating the brief's accessibility thesis.

## Testing Decisions

Outcome-focused `Phoenix.LiveViewTest`, mirroring the existing inspector LiveView
tests under `test/latchkey_web/live/`. Test external behaviour, not markup detail
(`has_element?` / `element/2` against IDs and hrefs).

- **Route + render:** `/inspector/glossary` renders the three lens-sections and
  known term anchors (an aggregate/ES heading, a domain-term heading).
- **Domain lens wired to source:** a known `CONTEXT.md` term renders on the page
  (guards the "render, don't copy" wiring from breaking).
- **Discoverability:** the persistent top-bar links to the glossary (asserted on
  the landing; present on every view) — #140.

**Deep docs (D8–D11, issue #131):**

- **Docs routes render:** `/inspector/docs/domain-model` and
  `/inspector/docs/context-map` each render, with a known section anchor present
  (e.g. `#7-arrears`) — guards the "point the machinery at two more files" wiring.
- **D9 relative-link rewrite (key):** a relative doc link (`domain-model.md`'s
  `[ADR 0005](adr/…)`) renders as an **absolute `github.com/…/blob/main/docs/…`**
  href, not a `/inspector/docs/adr/…` link that would 404; an already-absolute
  link (NSW RTA) is untouched.
- **D10 behavioural test (key):** the panes' `read_more` links target
  `/inspector/docs/domain-model#…` (and the context-map page) **in-app,
  same-tab** — no `github.com`, no `target="_blank"` — proving the brief's gap
  closed for the deep docs. (Replaces the superseded D4 test.)
- **D11 discoverability:** the persistent top-bar links to both deep docs
  (asserted on the landing; present on every view — #140); the glossary
  domain-lens caption links to `/inspector/docs/domain-model`.

**Accepted limitation:** the D7 anchor tripwire ("every DDD/ES entry names a
symbol or links a pane") is **not** automatically enforceable over freeform
markdown (a consequence of the D1 keystone). It is enforced by authoring
discipline + review, not CI. Coverage floor (85%) still applies to the
LiveView/render code, covered by the tests above.

## Out of Scope

- **Active-recall / Q&A format** — deferred, **gated on**: the brief's onboarding
  test showing readers don't retain from reading alone. Would likely reopen D1
  toward structured data. Not an open-ended "later".
- **Structured-data content model** — rejected at D1 in favour of markdown;
  re-propose only if active-recall or automated tripwire enforcement becomes a
  real need.
- **Editing `CONTEXT.md` for outward readability** — rejected at D6; maintenance
  cost + drift risk outweigh the dangling internal refs.
- **Rendering the full codebase in-app** — source *code* links go to GitHub
  (octocat, D5(c)); only the *learning content* — the glossary lenses **and** the
  deep prose docs (D8) — lives in-app. Un-rendered canonical docs (ADRs) remain
  GitHub link-outs (D9).
- **Auto-linking plain-text `§`-refs & cross-doc in-app resolution** — deferred at
  D9 behind named triggers, not undertaken now.

## Further Notes

No ADR was warranted: the decisions here (markdown vs. structured data, dedicated
route, anchor mechanics) are feature-scoped and reversible — none clear the
hard-to-reverse + surprising + real-trade-off bar. They live in this spec. The
issue #131 additions (D8–D11 — deep docs in-app, link handling, `read_more`
retarget, discoverability) are likewise feature-scoped and reversible, and stay
in this spec.
