# Spec: Developer view — an interactive, living-documentation ES/DDD inspector

> The *how* for the developer-view feature. The *why* lives in
> [`docs/brief/developer-view.md`](../brief/developer-view.md) — read it first;
> its Problem, Cut-line, and Success criteria are binding. This spec owns the
> **Implementation Decisions** and **Testing Decisions**, built inline as a
> `grill-spec` session resolves them.
>
> **Status: resolved.** Keystone + all branches (B1–B6) decided; no OPEN items.
> Ready for `to-tickets`. The ledger at the bottom tracks DECIDED / DEFERRED.

## Problem Statement

Latchkey applies a stack of DDD + event-sourcing concepts — bounded contexts,
aggregates, events, commands, projectors, ACLs, the payments seam — but they
live in only two places: **prose docs** (`context-map.md`, `domain-model.md`)
and **running-but-invisible code**. The prose describes the model in the
abstract; the code runs but is unreadable unless you poke Postgres or `iex`.
Neither makes the concepts *concrete and connected*. David is new to DDD and the
strongest way to consolidate the model is to see the concepts wired to real,
running events — and the same artifact doubles as living documentation for
colleagues and as a portfolio piece. (Full framing: the brief.)

## Solution

A separate **developer route**, distinct from the Property Manager view, that is
an **interactive, live event-stream inspector which doubles as living
documentation**. It:

- shows a **live, chronological feed of every event** in the system with its
  actual stored payload, navigable by the model's own structure — **bounded
  context → aggregate → stream**; the nav structure *is* the model map,
  populated with live data;
- for a selected stream, shows the ES money-shot side by side — raw **events**,
  the **aggregate state** they fold into, and the **read model** — so the
  write-model / read-model distinction is *shown*, not told;
- offers a **replay scrubber** over a stream's stored history that steps
  event-by-event and shows both the aggregate state **and the read model
  rebuilding at each step**, computed **in-memory over the selected event
  prefix** (a read-only pedagogical fold), never by rewinding the operational
  projector;
- surfaces new events **live** as the simulation / sweep emits them;
- carries **teaching scaffolding** — explanatory content about each concept in
  place — so the view functions as documentation, not just a data viewer.

## User Stories

1. As David, I want a separate developer route distinct from the PM view, so the
   ES/DDD "how it's built" story has its own home.
2. As David, I want a live chronological feed of every event in the system with
   its stored payload, so I can see the whole event log as one stream.
3. As David, I want to navigate by bounded context → aggregate → stream, so the
   model's own structure is the map.
4. As David, I want to select a tenancy stream and see raw events, aggregate
   state, and the read model side by side, so the write-model/read-model
   distinction is shown, not told.
5. As David, I want a replay scrubber that steps through a stream's stored
   history event-by-event, showing aggregate state and read model rebuilding at
   each step, so "events fold to state" is animated.
6. As David, I want events to appear live as the simulation emits them, so ES is
   shown in action, not just as static history.
7. As David, I want the view to carry explanatory documentation about each
   concept (event, aggregate, stream, context, ACL, projector, write-vs-read
   model, immutability), so it functions as living documentation and a learning
   artifact for colleagues.
8. As David, I want the read-model and aggregate panes computed by the *same*
   downstream implementation the operational projector uses, so what the view
   teaches is the real fold, not a lookalike.
9. As David, I want the log's immutability shown as a feature (no editing or
   deleting events), so a core ES lesson is visible.

10. As David, I want short concept captions *in* each pane, anchored to what I'm
    manipulating ("this is the aggregate — press play and watch it fold"), so the
    teaching is tied to live data, not abstract.
11. As David, I want the deep domain rules (why ≥14 days, the ACL translation,
    NSW grounding) to stay canonical in `domain-model.md` / `context-map.md` and
    be *linked* from the relevant pane, so there's a single source of truth and
    no drift.
12. As David (and a visiting colleague), I want a landing that renders the whole
    strategic context map — emitting contexts live and clickable, named-only
    contexts as honestly-labelled static boxes — so I get oriented before drilling
    in.

13. As David, I want Accounts shown honestly as an edge context — one `accounts`
    stream, events-only, no aggregate/read-model panes — so the deep-vs-edge
    distinction is visible rather than hidden.
14. As David, I want the ACL-1 seam on the orientation map, labelled with the
    language flip (payment → arrears reduction), and `source_payment_id` visible
    on payment rows, so the cross-context translation is legible.

15. As David, I want the scrubber to compute entirely server-side (no JS as the
    source of truth), so the fold I'm watching is the same one production runs.

16. As David, I want new events to stream into a live firehose feed and into the
    stream I'm viewing (following at head, pinned when I've scrubbed back), so ES
    is shown in motion without yanking me out of an exploration.

17. As a colleague with a link, I want to open the inspector at a public URL with
    no login and read the whole event story, so David can share it as a portfolio
    artifact.
18. As David the admin (follow-on), I want to issue commands to append events live
    from the view, so I can drive the simulation and demonstrate ES in action —
    while unauthenticated users stay read-only and nobody can update or delete
    events.
19. As David, I want each event row to show both `occurred_on` and `recorded_on`
    and flag when they diverge, so valid-time-vs-transaction-time (lazy accrual,
    forward-dated notices) is visible on the timeline.

## Implementation Decisions

### D1 — Keystone: one shared downstream fold, reused in-memory over a prefix (DECIDED)

The three panes and the scrubber **reuse the real domain fold** — there is no
display-only reimplementation. Concretely:

- **Extract a single shared fold-and-derive function.** The stream-fold that
  today lives inline in `ArrearsProjector.fold_stream/1` (`Enum.reduce(events,
  %Aggregate{}, &Aggregate.apply/2)` → `core`) plus the read-model derivation
  (`Tenancy.balance_cents` / `Tenancy.oldest_unpaid_due_date` / `Arrears`
  `days_behind`) is extracted into **one function that takes a list of events (a
  prefix) and returns the folded aggregate state + derived read-model fields**.
- **Both consumers call it.** The operational `ArrearsProjector` calls it with
  the **full stream** and upserts the result to Postgres. The dev-view inspector
  calls it with a **selected prefix**, **in-memory only — it never writes to the
  read-model tables** (`pm_tenancy_arrears`). One code path, so the inspector can
  never drift from production.
- **Panes:**
  - *Aggregate-state pane* = the folded `%Tenancy.State{}` core (via
    `Aggregate.apply` / `Tenancy.evolve`).
  - *Read-model pane* = the derived `Arrears` fields off that same core.
  - *Ledger pane* (double-entry timeline) = `Timeline.fold/1`, itself already a
    pure prefix fold.
- **`days_behind` during replay** is computed **as-at the prefix's last event
  `occurred_on`** (mirroring `Timeline.fold`, which already does days-behind
  as-at each row), so arrears visibly climb and fall through the scrub rather
  than always reading "today."
- **Consistency check (immutability made visible):** at the *full* prefix the
  in-memory recompute equals the live `Arrears` row — the view can surface this
  as "the read model is just a fold of the log."

This satisfies brief cut #4 (no operational projector rewind) by construction.

### D2 — Teaching layer: two altitudes, single source of truth for the deep model (DECIDED)

The view doubles as living documentation via a deliberate altitude split:

- **In-view (authored in the view): thin, interaction-anchored captions.** Short
  concept blurbs tied to the mechanic being shown ("this pane is the *aggregate*;
  it folds from the events on the left"). They describe the **interaction**, not
  the domain rules, so they stay bite-sized and drift-resistant.
- **Canonical, stays in docs, linked from the view: the deep rules & rationale.**
  Why ≥14 days, the ACL translation, NSW grounding — single-source in
  `domain-model.md` / `context-map.md`, surfaced via "read more" links. The view
  **never re-authors** the deep prose.
- **The strategic context map renders in-view as an orientation landing** —
  emitting contexts (Tenancy & Arrears; Accounts stub) **live and clickable**,
  named-only contexts (Maintenance, Inspections, Compliance, Leasing, BD) as
  **static boxes labelled "named only — not modelled."** This replaces the
  separate "Mermaid diagram in the docs" the brief originally pointed to; the
  rendered in-view map *is* the map. **This softened brief cut #2 — the edit was
  pushed back into `docs/brief/developer-view.md`.**

### D3 — Nav scope: honest context/aggregate/stream asymmetry; shallow seam in v1 (DECIDED)

The nav is **context → aggregate → stream**, rendered to reflect the model's real
asymmetry rather than force-fitting:

- **Tenancy & Arrears** (deep): one `Tenancy` aggregate → per-tenancy streams
  (`tenancy-<id>`; the 3 seeded, more as the sim runs). Full three-pane treatment
  (events / aggregate state / read model) + scrubber + ledger.
- **Accounts** (edge/stub): **no aggregate** (append-only edge, no write-side
  invariant) → a **single `"accounts"` stream** holding all payment facts. **Events
  pane only** — the *absence* of aggregate/read-model panes is a deliberate teaching
  point ("edge context: emits facts, folds no state"), carried by a D2 caption.
- **The ACL-1 seam is shown shallowly in v1:** the orientation map renders the
  ACL-1 edge between Accounts and Tenancy & Arrears, labelled with the language
  flip (*payment → arrears reduction*), and a `RentPaymentRecorded` row surfaces
  its `source_payment_id` so its Accounts origin is visible. The **deep
  cross-stream click-through tracer** (payment ⇄ its translated event) is
  **DEFERRED** — see the ledger.

### D4 — Replay scrubber: server-side, single-integer prefix, shared fold (DECIDED)

- **Compute server-side in the LiveView — no JS fold.** Client-side would be a
  second implementation of the D1 fold; explicitly rejected ("no JS as the source
  of truth"). The scrubber's whole state is one integer **`k`** (current position)
  in socket assigns; each change recomputes the panes via the **shared fold over
  the first `k` events (`Enum.take(events, k)`)**. Streams are short, so per-step
  server recompute is cheap.
- **UX:** `k` is a **prefix length** over `0..N` (`N` = event count) — `k = 0` is the
  empty prefix (before any event), `k = N` is the head (all `N` events). A position
  slider over that range, plus step-back / step-forward and a **play/pause** that
  auto-advances one event per ~1s (tunable LiveView timer tick, halting at the head).
  At position `k > 0`: highlight event `k - 1` (the last event in the prefix) and
  rebuild the **aggregate**, **read-model**, and **ledger** panes as-of the first `k`
  events, with `days_behind` as-at that event's `occurred_on` (D1).
- **Scrubber only on streams with state to fold — tenancy streams.** The Accounts
  `"accounts"` stream is events-only (no scrubber; at most a position highlighter),
  consistent with D3.

### D5 — Live feed: read-only broadcaster → Phoenix.PubSub fan-out (DECIDED)

- **One dedicated read-only Commanded event handler subscribes to the store and
  re-broadcasts each new event to `Phoenix.PubSub`** — a global `dev:events`
  firehose topic and per-stream topics (`dev:stream:<id>`). LiveViews subscribe on
  **connected mount only**. Chosen over per-LiveView Commanded subscriptions (which
  would be N durable subscriptions coupled to subscription lifecycle); PubSub gives
  one store subscription regardless of viewer count, and keeps the broadcaster
  out of the domain/write path.
- **The firehose feed uses LiveView streams** (`phx-update="stream"`) so the feed
  can't balloon memory.
- **Live-vs-scrub interaction: follow-at-head, pin-when-parked.** At the head
  (`k = N`) a new event advances to `N+1` (watch it fold in live); parked
  mid-history (`k < N`) the position holds and a "new events available" nudge
  offers a jump to head.
- **Scope boundary:** this owns the live *mechanism*, not the *cadence* of
  emission. A demoable live cadence depends on the sim producer and is
  **cross-referenced to the simulation spec, not owned here**. Per the brief, the
  inspector fully works over stored/seeded history; **v1 is not gated on a live
  producer running** — the feed is "genuinely live when the producer emits."

### D6 — Route & authorization: public read-only `/inspector` in all envs; admin-write is a follow-on (DECIDED)

- **Route: `/inspector`** — a **public, read-only** route enabled in **all
  environments including prod**, *not* behind the `dev_routes` compile flag (which
  is off in prod and would make the portfolio artifact unreachable). Distinct path
  from the compile-gated `/dev` LiveDashboard scope.
- **No auth for v1.** Justification (on the record for future reviewers): the view is
  **read-only, no commands, no mutation** (D1) → no meaningful attack surface; and
  there is **no user/auth system** in the codebase to lean on. It renders
  **domain-event data only — never runtime/system internals** (those stay behind
  LiveDashboard's gate), so "public" doesn't leak the host.
- **No PII on the log — an enforced control, not a synthetic-data assumption (ADR 0008).**
  Identity PII (tenant names, property address) is **never written to the event log**;
  log identity fields are a **non-PII allowlist** (`property_ref`, `tenancy_id`), and
  human labels are resolved at render from the disposable `Simulation.Directory` read
  model. The inspector can therefore render **every stored event** publicly without
  exposing names or addresses — the safeguard is the write-side invariant, not the
  assumption that the data happens to be synthetic.
- **Immutability is universal:** no update/delete of events, ever, for anyone —
  corrections are compensating appends (cut #3 intact).
- **Admin-write is a follow-on slice, not v1.** A later slice may let an
  authenticated **admin issue existing commands to append events** (drive the sim /
  author history). It introduces a net-new **auth system** (`phx.gen.auth` or Ash
  Authentication + an admin role) and **moves brief cut #1** (edit pushed into the
  brief). Sequenced after v1 to keep the read-only inspector thin and shippable —
  see the ledger.

### D7 — Bitemporal: minimal two-date display in v1; rich replay deferred (DECIDED)

- **v1 shows both envelope dates (`occurred_on`, `recorded_on`) on each event row
  and flags divergence** — `recorded_on` after `occurred_on` = lazy-accrual lag;
  `recorded_on` before effective = forward-dating. Both dates are already on the
  event structs (#38 landed, PR #53), so this is display + a thin D2 caption + a
  "read more" link to `domain-model.md §3` (which already explains envelope
  direction). Makes valid-time-vs-transaction-time visible for near-zero cost.
- **The rich two-axis transaction-time replay** ("what the system *knew* as-of
  recorded-date R" vs "the world as-of occurred-date O") is **DEFERRED** — see the
  ledger.

### D8 — Full paginated log: keyset over `$all`, newest-first, complements the firehose (DECIDED)

- **The firehose (D5) is a live *tail*** — it only shows events that arrive while
  watching and is capped at ~200 retained rows (memory bound). A separate read-only
  route (`/inspector/log`, issue #114) pages the **entire recorded history** across
  every stream — every event ever, oldest to newest. It **complements, never
  replaces**, the firehose (the firehose still runs on the right rail of the log
  page).
- **Keyset pagination over the global event number, not offset.** A page is one
  boundary integer over the `$all` stream's monotonic position: `nil` (head),
  `{:before, n}` (older), `{:after, n}` (newer), ~50/page, newest-first. Keyset is
  O(page) and stable under concurrent appends — a new head event never shifts an
  older page's contents, unlike a SQL `OFFSET`. The cursor lives in the URL
  (`?before=`/`?after=`), so pages are bookmarkable and the back button works; rows
  are a LiveView stream, so the page can't balloon memory.
- **Cross-stream identity via the Directory, not per-stream `property_ref`.** The
  per-stream event-log pane (#81) re-resolves a tenancy's identity from the
  commencement event's `property_ref` (it has the whole stream in hand). A single
  historical event out of stream context carries no `property_ref`, so the paginated
  log resolves identity from the disposable `Simulation.Directory` keyed by
  `tenancy_id` (ADR 0008). Because the Directory is seeded from the *same*
  `Identity.resolve/2`, displayed values are identical for seeded tenancies;
  unseeded refs render the honest `UNKNOWN` sentinel (consistent with D3). Both
  views share one resolver (`Latchkey.Inspector.Resolver`) so they cannot drift.
- **Rows link through to the stream detail, scrubbed to the event's position.** A
  deep (tenancy) row links to `/inspector/streams/:id?at=<stream_version>`, opening
  the D4 scrubber parked on that event; the Accounts edge folds no state (no
  scrubber), so it links plainly. Strictly read-only — a historical browser, never
  an editor (D6, brief cut #3).

## Testing Decisions

- The shared fold-and-derive function is **pure and unit-testable over
  arbitrary prefixes** — the natural home for the fold assertions. Key property:
  `fold(full stream)` equals what the operational `ArrearsProjector` writes
  (they are the same call), guarding against divergence.
- LiveView tests drive the inspector via stable element IDs (per the repo's
  Phoenix testing guidelines), asserting on presence of key elements rather than
  raw HTML.

## Out of Scope

- **Issuing commands from the view** — purpose is showing ES, not operating it
  (brief cut #1).
- **Non-event-emitting contexts as *inspectable* boxes** (Maintenance,
  Inspections, Compliance, Leasing, BD) — they render on the in-view strategic
  map as honestly-labelled "named only — not modelled" boxes (D2), never as
  drill-in-able streams masquerading as inspectable (brief cut #2, as amended).
- **Editing/deleting events** — immutability is shown as a feature (brief cut #3).
- **Operational projector rewind** — the panes are in-memory folds; the real
  projector/tables are never rewound (brief cut #4, D1).

## Ledger

- **DECIDED**: read-only (no commands) · only event-emitting contexts shown
  live · no log mutation (shown as a feature) · operational projector replay out
  (panes are in-memory folds) · separate dev route distinct from the PM view ·
  the view doubles as interactive living documentation (teaching scaffolding in
  scope) · **D1 keystone** — one shared downstream fold, reused in-memory over a
  prefix · **D2** — teaching layer's two-altitude split (thin in-view captions +
  linked canonical deep docs; strategic map renders in-view as an orientation
  landing; brief cut #2 softened & edited into the brief) · **D3** — nav renders
  the real context/aggregate/stream asymmetry (Accounts = events-only edge, no
  aggregate); ACL-1 seam shown shallowly in v1 · **D4** — scrubber is server-side,
  single-integer `k` over the shared fold, tenancy-streams-only · **D5** — live
  feed via a read-only broadcaster → PubSub fan-out; follow-at-head/pin-when-parked;
  live producer cadence cross-referenced to the sim spec, not gating v1 · **D6** —
  public read-only `/inspector` in all envs, no auth for v1, domain-data-only,
  immutability universal; admin-write is a follow-on slice · **D7** — minimal
  two-date (bitemporal) display + divergence flag in v1 · **D8** — full paginated
  log (`/inspector/log`): keyset over the `$all` stream, newest-first, ~50/page,
  complements the firehose; cross-stream identity via the Directory; rows deep-link
  scrubbed to position.
- **OPEN**: none — all branches resolved.
- **DEFERRED**:
  - **deep cross-stream ACL-1 seam tracer** (click a payment in the `accounts`
    stream → jump to its translated `RentPaymentRecorded` in the tenancy stream,
    and back) — gated on **the core inspector + scrubber landing** (v1).
  - **admin-write + auth slice** (authenticated admin issues existing commands to
    append events; introduces `phx.gen.auth`/Ash Authentication + admin role;
    read-only stays the public default; no event update/delete ever) — gated on
    **the read-only inspector v1 landing**.
  - **rich two-axis transaction-time replay** (replay what the system *knew*
    as-of a recorded-date vs the world as-of an occurred-date) — gated on **v1
    landing + the minimal two-date display proving the second axis is worth it**.
