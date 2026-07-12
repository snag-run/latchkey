# Prototype — /inspector layout spike

**Question:** what should the read-only ES/DDD inspector (`/inspector`, spec
`docs/spec/developer-view.md`, run plan #79–#86) *look like* — before we
implement eight vertical slices into one LiveView?

**Artifact:** `inspector-layouts.html` (throwaway, self-contained).
Live: https://claude.ai/code/artifact/fc9275b1-d4a5-4186-84f9-7431ae83b2a9

Three structurally-different layouts, flip via floating bar / arrow keys. Fake
in-memory data shaped like the real domain; the scrubber runs the real prefix
fold (D1) in JS. Tenant names are invented (synthetic, no real PII); stream ids
(`tenancy-<slug>`) shown alongside.

- **A — Workbench.** IDE shell — nav tree rail, gridded panes, docked scrubber, firehose rail.
- **B — Living document.** Vertical teaching scroll, events↓aggregate↓read-model↓ledger, prose captions.
- **C — Bento dashboard.** Global scrubber bar + at-a-glance pane grid + footer firehose ticker.

**Verdict (2026-07-13):** **A — Workbench** is the chosen direction (David).
IDE shell: context→aggregate→stream nav rail, four panes gridded, scrubber
docked bottom, firehose right rail. Fold into #80 (shell + landing + nav) and
the pane slices. **DECIDED: weave in B's connective teaching captions**
("↓ these events fold into the aggregate", "…derives the read model") between
the panes — the living-documentation hook, carried into #81/#83/#84 pane headers.

**Ledger requirement (David, domain call):** the ledger MUST show **Paid from /
Paid to** (the rental period each charge covers) — "integral to a ledger."
Source = `Timeline.Entry.period_from` / `period_to` (already exist). Half-open
`[from, to)` — "Paid to" is exclusive; next period's "Paid from" repeats it.
Blank on payment/reversal/notice rows (only rent charges carry a period).
→ **Fold into #84's acceptance criteria** (double-entry ledger pane).

**Firehose is clickable (David, 2026-07-13) → fold into #82.** Feed emits real
events; clicking a firehose row opens that exact event in its owning stream and
(tenancy) scrubs to its position so the panes fold to it. Not just a ticker.

**Every event row names its property AND tenant (David, 2026-07-13) → fold into #81.**
A small line showing the **property (address)** + **tenant** + `tenancy-<id>` on
each event (property leads — it's the primary PM identifier), so a row is
self-describing out of context — supports the tribunal-evidence goal. Also in the
firehose. Accounts edge rows derive it from the payment `holder` (map ref →
tenant/property; show `UNKNOWN` sentinel honestly). NB the real domain has no
tenant/property fields — they're display labels off the `tenancy_id`; the
inspector needs a tenancy→{property,tenant} lookup (seed/reference data), which
does not exist yet. Prototype refs: `propInfo` / `eventProp` / `openFirehose`.
_(Tried to post these to issues #81/#82; the external-write was auto-denied —
they live here for now, fold into the #81/#82 dispatch prompts.)_

**Wave A LAUNCHED (2026-07-13):** #79 (`feat/79-shared-fold`, partition 1) ∥
#80 (`feat/80-inspector-shell`, partition 2) — both in isolated worktrees,
driving to green precommit + a PR against `main`. Awaiting completion.
