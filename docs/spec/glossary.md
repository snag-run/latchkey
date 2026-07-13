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

### D3 — Placement: a dedicated `/inspector/glossary` route, advertised from the landing

A dedicated **`/inspector/glossary`** route — a `:glossary` live action on
`InspectorLive`, added **inside the existing `live_session :inspector`** (not a
standalone route, so the inspector's session contract is preserved) — renders the
three lens-sections on one scannable page — domain
(from `CONTEXT.md`), DDD, ES — each **term a heading with a fragment anchor** for
deep-linking. The **orientation landing advertises it** with a small entry-point
link ("Reference / Glossary"). Rejected: folding the glossary into the landing —
three lenses of terms bloat the orientation map and make per-term deep-linking
awkward.

### D4 — Redirect the existing `read_more` links in-app

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

## Testing Decisions

Outcome-focused `Phoenix.LiveViewTest`, mirroring the existing inspector LiveView
tests under `test/latchkey_web/live/`. Test external behaviour, not markup detail
(`has_element?` / `element/2` against IDs and hrefs).

- **Route + render:** `/inspector/glossary` renders the three lens-sections and
  known term anchors (an aggregate/ES heading, a domain-term heading).
- **Domain lens wired to source:** a known `CONTEXT.md` term renders on the page
  (guards the "render, don't copy" wiring from breaking).
- **D4 behavioural test (key):** the panes' `read_more` links target
  `/inspector/glossary#…` in-app, not `github.com` — proves the brief's gap
  closed.
- **Discoverability:** the `:landing` orientation map shows the glossary
  entry-point link.

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
- **Rendering the full codebase in-app** — source links go to GitHub (octocat,
  D5); only the *learning content* lives in-app.

## Further Notes

No ADR was warranted: the decisions here (markdown vs. structured data, dedicated
route, anchor mechanics) are feature-scoped and reversible — none clear the
hard-to-reverse + surprising + real-trade-off bar. They live in this spec.
