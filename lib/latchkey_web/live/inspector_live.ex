defmodule LatchkeyWeb.InspectorLive do
  @moduledoc """
  Root LiveView for the read-only ES/DDD **inspector** (spec developer-view.md,
  decisions D2/D3/D6).

  This slice is the **web spine**: the public `/inspector` route, the Workbench
  shell (nav rail · content · live firehose), and the orientation-map landing. It
  also hosts the **event-log pane** (issue #81, D3/D7) — a selected stream's raw,
  immutable events rendered in-memory with full payloads, both envelope dates + a
  divergence flag, and property-leading identity; the `accounts` edge renders
  through the same pane, events-only. Deeper slices hang the aggregate / read-model
  fold and the replay scrubber off this shell.

  The firehose (spec D5) subscribes to `Latchkey.Inspector.Broadcaster`'s
  global `dev:events` PubSub topic on connected mount and appends new events
  live via a LiveView stream (`LatchkeyWeb.Inspector.Firehose`), following at
  head. Each row is clickable and carries its `{stream_id, position}`, but
  navigating into a stream-detail view at that position is issue #86 — this
  slice only acknowledges the click structurally.

  Strictly read-only: it navigates and renders domain-event data. It issues no
  commands and exposes no create/update/delete affordance. The log is
  append-only / immutable.
  """
  use LatchkeyWeb, :live_view

  import LatchkeyWeb.Inspector.EventLog
  import LatchkeyWeb.Inspector.Firehose
  import LatchkeyWeb.Inspector.LedgerPane
  import LatchkeyWeb.Inspector.Scrubber
  import LatchkeyWeb.Inspector.StatePanes
  import LatchkeyWeb.InspectorComponents

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.EventStore
  alias Latchkey.Inspector.Broadcaster
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.ArrearsFold
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.PropertyManagement.Timeline
  alias Latchkey.Simulation.Directory
  alias Latchkey.Simulation.Identity

  # Bound on the firehose feed's live retained rows — old rows fall off the head
  # as new ones arrive, so the stream can't balloon memory over a long-running
  # session (spec D5: "LiveView streams ... so the feed can't balloon memory").
  @firehose_limit 200

  # The replay scrubber's auto-advance cadence (spec D4: "~1s per event"). The tick
  # is a **server-side** self-scheduled message (`Process.send_after/3`), not a client
  # timer — the fold runs server-side, so play is just repeated server steps. Made
  # configurable so tests drive advancement by hand without racing a real 1s timer.
  @tick_interval_ms Application.compile_env(:latchkey, [:inspector, :scrubber_tick_ms], 1000)

  # ── Static context map (spec D2/D3) ─────────────────────────────────────────
  # The named-only subdomains (context-map.md) — rendered as honestly-labelled
  # "named only — not modelled" boxes, never as inspectable streams.
  @named_contexts [
    %{slug: "maintenance", name: "Maintenance"},
    %{slug: "inspections", name: "Inspections"},
    %{slug: "compliance", name: "Compliance"},
    %{slug: "leasing", name: "Leasing"},
    %{slug: "business-development", name: "Business Development"}
  ]

  @acl_edge_label "payment → arrears reduction"

  # Canonical deep-model docs live in the repo (spec D2: the view links, never
  # re-authors, the deep prose). Point at the GitHub source so the public
  # portfolio artifact's "read more" links resolve.
  @docs %{
    context_map: "https://github.com/snag-run/latchkey/blob/main/docs/context-map.md",
    domain_model: "https://github.com/snag-run/latchkey/blob/main/docs/domain-model.md"
  }

  @accounts_context %{
    id: "accounts",
    name: "Accounts",
    kind: :edge,
    aggregate: nil,
    blurb:
      "Edge context — append-only payment facts. Emits facts, folds no state: no aggregate, no read model.",
    streams: [%{id: "accounts", label: "accounts", status: nil, tone: :info}]
  }

  @tenancy_context_base %{
    id: "tenancy",
    name: "Tenancy & Arrears",
    kind: :deep,
    aggregate: "Tenancy",
    blurb:
      "Deep context — a Tenancy aggregate with per-tenancy streams. Full write model, read model and ledger."
  }

  @impl true
  def mount(_params, _session, socket) do
    tenancy_context = Map.put(@tenancy_context_base, :streams, list_tenancy_streams())
    contexts = [tenancy_context, @accounts_context]

    # Connected mount only (spec D5) — the static render on initial HTTP GET
    # doesn't need a live subscription, only the socket that survives.
    if connected?(socket) do
      :ok = Phoenix.PubSub.subscribe(Latchkey.PubSub, Broadcaster.global_topic())
    end

    socket =
      socket
      |> assign(:contexts, contexts)
      |> assign(:tenancy_context, tenancy_context)
      |> assign(:accounts_context, @accounts_context)
      |> assign(:named_contexts, @named_contexts)
      |> assign(:acl_edge_label, @acl_edge_label)
      |> assign(:docs, @docs)
      |> assign(:stream_found?, false)
      # Replay-scrubber state (spec D4). The whole thing is one integer `k`; the
      # rest is bookkeeping. Defaulted here so every render path is safe before a
      # deep stream is selected.
      |> assign(:recorded, [])
      |> assign(:scrubber_k, 0)
      |> assign(:scrubber_n, 0)
      |> assign(:scrubber_playing?, false)
      |> assign(:scrubber_timer, nil)
      |> assign(:highlight_version, nil)
      # Per-stream live updates (spec D5, issue #86): whether live events have
      # landed while parked mid-history (drives the "new events available" nudge),
      # and the `dev:stream:<id>` topic this socket is currently subscribed to (so
      # navigating between streams unsubscribes the old one before subscribing).
      |> assign(:new_events_available?, false)
      |> assign(:subscribed_stream_topic, nil)
      |> stream(:firehose, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ── Live updates (spec D5) ──────────────────────────────────────────────────
  # Every event Latchkey.Inspector.Broadcaster re-broadcasts lands here, from two
  # subscriptions: the global `dev:events` firehose (mount) and — when a stream is
  # open — its own `dev:stream:<id>` topic (issue #86). One clause serves both:
  #   • the global firehose feed always appends the row;
  #   • if the event belongs to the *open* deep stream, it also folds into the
  #     stream-detail panes (follow-at-head) or raises the nudge (pin-when-parked).
  # The active stream is delivered on both topics, so this fires twice for it; both
  # steps are idempotent (`stream_insert` keys by id; `live_advance/1` no-ops once
  # the store read shows nothing new), so the duplicate is harmless.
  @impl true
  def handle_info({:dev_event, event, metadata}, socket) do
    row = to_firehose_row(event, metadata)

    socket =
      socket
      |> stream_insert(:firehose, row, at: 0, limit: @firehose_limit)
      |> maybe_live_advance(metadata)

    {:noreply, socket}
  end

  # ── Auto-advance tick (spec D4: ~1s/event, server-side) ─────────────────────
  # Guarded on `scrubber_playing?` so a stale tick left over after a pause is inert.
  # Advances one event; on reaching the head it halts (auto-pauses), otherwise it
  # schedules the next tick.
  def handle_info(:scrubber_tick, %{assigns: %{scrubber_playing?: true}} = socket) do
    next = socket.assigns.scrubber_k + 1

    socket =
      if next >= socket.assigns.scrubber_n do
        socket |> assign_prefix(socket.assigns.scrubber_n) |> assign(:scrubber_playing?, false)
      else
        socket |> assign_prefix(next) |> schedule_tick()
      end

    {:noreply, socket}
  end

  def handle_info(:scrubber_tick, socket), do: {:noreply, socket}

  # Structural click-to-scrub only (spec D5 / issue #82 scope): the row already
  # carries its {stream_id, position}, but there is no stream-detail view to
  # navigate into yet — that lands at issue #86, once it exists. Never use a
  # ~p route to a path that doesn't compile.
  @impl true
  def handle_event(
        "firehose_row_click",
        %{"stream_id" => _stream_id, "position" => _position},
        socket
      ) do
    # Deferred to #86: navigate to the stream-detail view, scrubbed to this
    # {stream_id, position}. (Not spelled as a TODO tag — this repo's credo
    # config fails the gate on Credo.Check.Design.TagTODO.)
    {:noreply, socket}
  end

  # ── Replay-scrubber controls (spec D4) ──────────────────────────────────────
  # Every control is server-side: it moves the single integer `k` and re-folds the
  # prefix. Manual controls pause any running auto-advance so the two never fight.

  # Slider drag: a bare `<input type="range" name="k">` posts its value. Parse and
  # clamp defensively; `assign_prefix/2` re-clamps, so a bogus value is harmless.
  @impl true
  def handle_event("scrub", %{"k" => k}, socket) do
    {:noreply, socket |> cancel_play() |> assign_prefix(to_int(k, socket.assigns.scrubber_k))}
  end

  def handle_event("step_back", _params, socket) do
    {:noreply, socket |> cancel_play() |> assign_prefix(socket.assigns.scrubber_k - 1)}
  end

  def handle_event("step_forward", _params, socket) do
    {:noreply, socket |> cancel_play() |> assign_prefix(socket.assigns.scrubber_k + 1)}
  end

  # Play/pause. Pausing cancels the tick. Playing schedules the first tick; if we are
  # already parked at the head there is nothing to fold forward, so a play there
  # rewinds to the empty prefix first, giving a satisfying full replay.
  def handle_event("toggle_play", _params, socket) do
    socket =
      if socket.assigns.scrubber_playing? do
        cancel_play(socket)
      else
        start_position =
          if socket.assigns.scrubber_k >= socket.assigns.scrubber_n,
            do: 0,
            else: socket.assigns.scrubber_k

        socket
        |> assign_prefix(start_position)
        |> assign(:scrubber_playing?, true)
        |> schedule_tick()
      end

    {:noreply, socket}
  end

  # Nudge action (spec D5, issue #86): parked mid-history with newer events landed,
  # the user jumps to the head — fold the whole live history in and resume following
  # (at k = N, the next live event follows automatically). Cancels any auto-advance.
  def handle_event("jump_to_head", _params, socket) do
    {:noreply, socket |> cancel_play() |> assign_prefix(socket.assigns.scrubber_n)}
  end

  defp to_firehose_row(event, %{event_number: event_number, stream_id: stream_id} = metadata) do
    %{
      id: event_number,
      stream_id: stream_id,
      position: Map.get(metadata, :stream_version),
      event_type: event_type(event),
      timestamp: Map.get(metadata, :created_at)
    }
  end

  defp event_type(%module{}), do: module |> Module.split() |> List.last()

  # ── Per-stream live updates (spec D5, issue #86) ────────────────────────────
  # A live event that belongs to the *open* deep stream folds into the stream-detail
  # panes. Only deep (tenancy) streams fold state; the Accounts edge (D3) and any
  # other stream's events are ignored here (the firehose already carries them).
  defp maybe_live_advance(socket, %{stream_id: stream_id}) do
    if socket.assigns[:active_stream] == stream_id and socket.assigns[:stream_kind] == :deep do
      live_advance(socket)
    else
      socket
    end
  end

  # Fold the newly-appended event(s) into the in-memory view — strictly read-only:
  # re-read the store (the broadcaster's event is already persisted, D5) and refresh
  # the recorded log. The read is idempotent, so the active stream's duplicate
  # delivery (global + per-stream topic) no-ops here once nothing new remains.
  #
  #   • at head (`k = N`): follow — advance to `N+1` and re-fold all panes live.
  #   • parked (`k < N`): hold `k`; raise the "new events available" nudge.
  defp live_advance(socket) do
    stream_id = socket.assigns.active_stream
    recorded = read_stream(stream_id)
    new_n = length(recorded)
    old_n = socket.assigns.scrubber_n

    if new_n <= old_n do
      socket
    else
      at_head? = socket.assigns.scrubber_k >= old_n

      socket =
        socket
        |> assign(:recorded, recorded)
        |> assign(:event_rows, build_event_rows(stream_id, :deep, recorded))
        |> assign(:scrubber_n, new_n)

      if at_head? do
        assign_prefix(socket, new_n)
      else
        assign(socket, :new_events_available?, true)
      end
    end
  end

  # Move the per-stream live subscription to `topic` (or drop it when `nil`), only on
  # a connected socket (spec D5: subscribe on connected mount only). Unsubscribes the
  # previously-open stream's topic first so a socket is never subscribed to two.
  defp resubscribe_stream(socket, topic) do
    cond do
      not connected?(socket) -> socket
      socket.assigns[:subscribed_stream_topic] == topic -> socket
      true -> switch_stream_subscription(socket, topic)
    end
  end

  defp switch_stream_subscription(socket, topic) do
    if previous = socket.assigns[:subscribed_stream_topic] do
      Phoenix.PubSub.unsubscribe(Latchkey.PubSub, previous)
    end

    if topic, do: Phoenix.PubSub.subscribe(Latchkey.PubSub, topic)

    assign(socket, :subscribed_stream_topic, topic)
  end

  defp apply_action(socket, :landing, _params) do
    socket
    |> cancel_play()
    # Leaving all streams: drop the per-stream live subscription and any nudge.
    |> resubscribe_stream(nil)
    |> assign(:new_events_available?, false)
    |> assign(:page_title, "Inspector — orientation")
    |> assign(:active_stream, nil)
  end

  defp apply_action(socket, :stream, %{"stream_id" => stream_id}) do
    # Navigating away from a stream stops any in-flight auto-advance (spec D4).
    socket = cancel_play(socket)

    # Validate against the streams enumerable at mount, so a typo'd or stale URL
    # surfaces as "unknown" instead of masquerading as a valid Tenancy stream.
    case owning_context(socket.assigns.contexts, stream_id) do
      nil ->
        socket
        |> resubscribe_stream(nil)
        |> assign(:new_events_available?, false)
        |> assign(:page_title, "Inspector — unknown stream")
        |> assign(:active_stream, nil)
        |> assign(:stream_found?, false)
        |> assign(:unknown_stream_id, stream_id)

      context ->
        # One store read feeds both the event-log pane and the shared fold, so the
        # two panes can never see different histories (D1). It is held in assigns so
        # the scrubber can re-fold arbitrary prefixes of it without re-reading (D4).
        recorded = read_stream(stream_id)

        socket
        # Subscribe to this stream's live topic (spec D5, issue #86); a fresh open
        # starts at the head, so no nudge is pending.
        |> resubscribe_stream(Broadcaster.stream_topic(stream_id))
        |> assign(:new_events_available?, false)
        |> assign(:page_title, "Inspector — #{stream_id}")
        |> assign(:active_stream, stream_id)
        |> assign(:stream_found?, true)
        |> assign(:context_name, context.name)
        |> assign(:stream_kind, context.kind)
        |> assign(:recorded, recorded)
        |> assign(:event_rows, build_event_rows(stream_id, context.kind, recorded))
        |> init_scrubber(context.kind, recorded)
    end
  end

  # ── Replay scrubber (issue #85, spec D4) ────────────────────────────────────
  # The scrubber's whole state is one integer `k` (prefix length over 0..N). Each
  # control moves `k`; `assign_prefix/2` then re-folds the first `k` events through
  # the **same shared fold** (`ArrearsFold` / `Timeline.fold`) the operational
  # projector runs (D1) — entirely server-side, no JS fold (D4). The Accounts edge
  # folds no state (D3), so it gets no scrubber and no fold panes.
  defp init_scrubber(socket, :edge, _recorded) do
    socket
    |> assign(:scrubber_n, 0)
    |> assign(:scrubber_k, 0)
    |> assign(:scrubber_playing?, false)
    |> assign(:highlight_version, nil)
    |> assign(:aggregate_state, nil)
    |> assign(:read_model, nil)
    |> assign(:consistency, nil)
    |> assign(:ledger_entries, nil)
  end

  # Deep (tenancy) streams open at the head (k = N), so the default view is the full
  # history — the same panes prior slices showed — now with the head event highlighted.
  defp init_scrubber(socket, _deep, recorded) do
    n = length(recorded)

    socket
    |> assign(:scrubber_n, n)
    |> assign(:scrubber_playing?, false)
    |> assign_prefix(n)
  end

  # Recompute every deep pane as-of the first `k` events. `k` is clamped to 0..N so
  # a bogus slider value can never fold past the head or before the empty prefix.
  # The highlighted event is the prefix's last one (stream_version = k, since commit
  # order is 1-based); an empty prefix highlights nothing (spec D4).
  defp assign_prefix(socket, k) do
    recorded = socket.assigns.recorded
    n = length(recorded)
    k = k |> max(0) |> min(n)
    prefix = Enum.take(recorded, k)

    highlight_version =
      case k do
        0 -> nil
        _ -> Enum.at(recorded, k - 1).stream_version
      end

    socket
    |> assign(:scrubber_k, k)
    |> assign(:highlight_version, highlight_version)
    # Reaching the head clears the nudge (spec D5): parked events are now folded in,
    # and at `k = N` we are following again.
    |> maybe_clear_nudge(k, n)
    |> assign_fold_panes(prefix)
  end

  defp maybe_clear_nudge(socket, k, n) when k >= n,
    do: assign(socket, :new_events_available?, false)

  defp maybe_clear_nudge(socket, _k, _n), do: socket

  # ── Aggregate-state + read-model + ledger panes (issue #83/#84, spec D1/D2) ──
  # Folds a **prefix** through the **shared** `ArrearsFold.fold_and_derive/1` — the
  # very code path the operational `ArrearsProjector` runs at full history, so the
  # panes can never drift from production (D1). `days_behind` is reckoned as-at the
  # prefix's last event `occurred_on` (D1/D4), so arrears climb and fall on the scrub.
  # In-memory only: it reads the live `Arrears` row solely to reconcile against (at the
  # head), and never writes any read-model table (brief cut #4).
  defp assign_fold_panes(socket, prefix) do
    derived =
      prefix
      |> Enum.map(& &1.data)
      |> ArrearsFold.fold_and_derive()

    tenancy_id = String.replace_prefix(socket.assigns.active_stream, "tenancy-", "")
    live = live_arrears(tenancy_id)

    consistency =
      case live do
        nil -> :no_live_row
        row -> ArrearsFold.reconcile(derived, row)
      end

    socket
    |> assign(:aggregate_state, derived.core)
    |> assign(:read_model, derived)
    |> assign(:consistency, consistency)
    |> assign(:ledger_entries, ledger_entries(prefix))
  end

  # ── Ledger pane (issue #84, spec D1, ADR 0006) ──────────────────────────────
  # The double-entry accounting lens on the same stream, via `Timeline.fold/1` —
  # the pure, compute-on-read prefix fold (never a parallel reimplementation). The
  # same `recorded` events feed the event-log, fold and ledger panes, so all three
  # see one history. Pairs each event with its per-stream `stream_version` (the
  # ledger's same-day tie-breaker), and reads no store, writes nothing (in-memory).
  defp ledger_entries(recorded) do
    recorded
    |> Enum.map(fn r -> {r.stream_version, r.data} end)
    |> Timeline.fold()
  end

  # Schedule the next auto-advance tick (server-side, spec D4). The returned timer
  # ref is held so a pause can cancel a not-yet-fired tick.
  defp schedule_tick(socket) do
    ref = Process.send_after(self(), :scrubber_tick, @tick_interval_ms)
    assign(socket, :scrubber_timer, ref)
  end

  # Stop auto-advance: cancel any pending tick and clear the playing flag. Safe to
  # call unconditionally (idempotent) — used on pause and on any manual control.
  defp cancel_play(socket) do
    case socket.assigns[:scrubber_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    socket
    |> assign(:scrubber_timer, nil)
    |> assign(:scrubber_playing?, false)
  end

  # Parse the slider's string value; fall back to the current position on garbage.
  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> default
    end
  end

  defp to_int(_value, default), do: default

  # The live, persisted read-model row for this tenancy (or nil), read to reconcile
  # the in-memory recompute against — never written back (brief cut #4).
  defp live_arrears(tenancy_id) do
    Arrears
    |> Ash.read!()
    |> Enum.find(&(&1.tenancy_id == tenancy_id))
  end

  # ── Event-log pane (issue #81, spec D3/D7) ──────────────────────────────────
  # Reads a stream's raw events from the store and builds display rows: full
  # payloads, both envelope dates + a divergence flag (D7), and property-leading
  # identity. In-memory only — no fold, no write. Tenancy streams resolve identity
  # once off the stream's `property_ref` + `tenancy_id` (Identity.resolve/2); the
  # `accounts` edge derives identity from each payment `holder`, honestly showing
  # UNKNOWN when unresolvable (D3).
  defp build_event_rows(_stream_id, :edge, recorded) do
    directory = directory_map()
    holders = payment_holders(recorded)

    Enum.map(recorded, fn r -> base_row(r, accounts_identity(r.data, directory, holders)) end)
  end

  defp build_event_rows(stream_id, _deep, recorded) do
    identity = tenancy_identity(stream_id, recorded)

    Enum.map(recorded, fn r -> base_row(r, identity) end)
  end

  # Raw events in commit order; a not-yet-written stream reads as empty.
  defp read_stream(stream_id) do
    case EventStore.stream_forward(stream_id) do
      {:error, :stream_not_found} -> []
      events -> Enum.to_list(events)
    end
  end

  defp base_row(recorded, identity) do
    data = recorded.data
    occurred_on = to_date(Map.get(data, :occurred_on))
    recorded_on = to_date(Map.get(data, :recorded_on))

    %{
      version: recorded.stream_version,
      type: short_type(data),
      occurred_on: occurred_on,
      recorded_on: recorded_on,
      divergent?: divergent?(occurred_on, recorded_on),
      identity: identity,
      payload: payload_pairs(data)
    }
  end

  defp short_type(%module{}), do: module |> Module.split() |> List.last()

  # Payload columns deserialize dates as ISO strings (JSON serializer); coerce so
  # the divergence check compares real dates, not string shapes.
  defp to_date(%Date{} = date), do: date

  defp to_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp to_date(_), do: nil

  defp divergent?(%Date{} = occurred, %Date{} = recorded),
    do: Date.compare(occurred, recorded) != :eq

  defp divergent?(_, _), do: false

  defp payload_pairs(%_struct{} = data) do
    data
    |> Map.from_struct()
    |> Enum.sort_by(fn {key, _value} -> Atom.to_string(key) end)
  end

  # ── Identity resolution ─────────────────────────────────────────────────────
  # Tenancy stream: one identity for the whole stream, keyed off the commencement
  # event's non-PII `property_ref` + the stream's `tenancy_id` (ADR 0008). Property
  # leads — it is the primary PM identifier.
  defp tenancy_identity(stream_id, recorded) do
    tenancy_id = String.replace_prefix(stream_id, "tenancy-", "")

    property_ref =
      Enum.find_value(recorded, fn r ->
        case r.data do
          %TenancyCommenced{property_ref: ref} -> ref
          _ -> nil
        end
      end)

    if is_binary(property_ref) and property_ref != "" do
      %{tenant_name: tenant, property_address: property} =
        Identity.resolve(tenancy_id, property_ref)

      %{property: property, tenant: tenant, ref: stream_id, resolved?: true}
    else
      unknown_identity(stream_id)
    end
  end

  # Accounts edge: identity derives from the payment `holder` (a `tenancy_ref`).
  # A reversal carries no holder of its own, so it inherits the holder of the
  # payment it reverses. Unresolvable holders honestly render UNKNOWN (D3).
  defp accounts_identity(%PaymentReceived{holder: holder}, directory, _holders) do
    holder_identity(holder, directory)
  end

  defp accounts_identity(%{reverses: reverses}, directory, holders) do
    holder_identity(Map.get(holders, reverses), directory)
  end

  defp accounts_identity(_data, directory, _holders), do: holder_identity(nil, directory)

  defp holder_identity(holder, directory) do
    with true <- Accounts.known_holder?(holder),
         tenancy_id = String.replace_prefix(holder, "tenancy-", ""),
         %{tenant_name: tenant, property_address: property} <- Map.get(directory, tenancy_id) do
      %{property: property, tenant: tenant, ref: holder, resolved?: true}
    else
      _ -> unknown_identity(holder)
    end
  end

  defp unknown_identity(ref) do
    ref = if is_binary(ref) and ref != "", do: ref, else: "UNKNOWN"
    %{property: "UNKNOWN", tenant: "UNKNOWN", ref: ref, resolved?: false}
  end

  defp payment_holders(recorded) do
    for %{data: %PaymentReceived{payment_id: payment_id, holder: holder}} <- recorded,
        into: %{},
        do: {payment_id, holder}
  end

  # A disposable, non-PII display lookup keyed by `tenancy_id` (ADR 0008 Directory).
  defp directory_map do
    Directory
    |> Ash.read!()
    |> Map.new(fn dir ->
      {dir.tenancy_id, %{tenant_name: dir.tenant_name, property_address: dir.property_address}}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.inspector flash={@flash}>
      <div id="inspector" class="flex flex-1 min-h-0">
        <aside class="w-64 shrink-0 overflow-y-auto p-3 border-r border-base-300 bg-base-100">
          <.nav_rail
            contexts={@contexts}
            named_contexts={@named_contexts}
            active_stream={@active_stream}
          />
        </aside>

        <div class="flex flex-1 min-w-0">
          <main class="flex-1 min-w-0 overflow-y-auto p-6">
            <%= cond do %>
              <% @live_action == :stream and @stream_found? -> %>
                <nav id="inspector-breadcrumb" class="mb-4 text-xs text-base-content/50">
                  <.link patch={~p"/inspector"} class="hover:text-base-content">Contexts</.link>
                  <span aria-hidden="true">/</span>
                  <span class="text-base-content">{@context_name}</span>
                  <span aria-hidden="true">/</span>
                  <span class="font-mono text-base-content">{@active_stream}</span>
                </nav>
                <.events_pane
                  stream_id={@active_stream}
                  context_name={@context_name}
                  kind={@stream_kind}
                  rows={@event_rows}
                  docs={@docs}
                  highlight_version={@highlight_version}
                />
                <%!-- The server-side replay scrubber: fold the log event-by-event (#85, D4). --%>
                <%!-- Deep (tenancy) streams only; the Accounts edge folds no state (D3/D4). --%>
                <.scrubber
                  :if={@stream_kind == :deep}
                  k={@scrubber_k}
                  n={@scrubber_n}
                  playing?={@scrubber_playing?}
                  new_events_available?={@new_events_available?}
                  docs={@docs}
                />
                <%!-- The write-vs-read money-shot: what the log folds into (#83, D1/D2). --%>
                <%!-- Deep (tenancy) streams only; the Accounts edge folds no state (D3). --%>
                <.fold_panes
                  :if={@stream_kind == :deep}
                  stream_id={@active_stream}
                  state={@aggregate_state}
                  derived={@read_model}
                  consistency={@consistency}
                  docs={@docs}
                />
                <%!-- The double-entry accounting lens on the same fold (#84, D1). --%>
                <%!-- Deep (tenancy) streams only; the Accounts edge folds no state (D3). --%>
                <.ledger_pane
                  :if={@stream_kind == :deep}
                  stream_id={@active_stream}
                  entries={@ledger_entries}
                  read_model_balance_cents={@read_model.balance_cents}
                  docs={@docs}
                />
              <% @live_action == :stream -> %>
                <.stream_not_found stream_id={@unknown_stream_id} />
              <% true -> %>
                <.orientation_map
                  deep_context={@tenancy_context}
                  edge_context={@accounts_context}
                  named_contexts={@named_contexts}
                  acl_edge_label={@acl_edge_label}
                  docs={@docs}
                />
            <% end %>
          </main>

          <aside class="w-72 shrink-0 border-l border-base-300 bg-base-100">
            <.firehose_feed stream={@streams.firehose} />
          </aside>
        </div>
      </div>
    </Layouts.inspector>
    """
  end

  # ── Read model → nav streams ────────────────────────────────────────────────
  # Lists the live tenancy streams from the Arrears read model (one row per
  # seeded/live tenancy). Read-only; sorted for stable ordering + stable DOM ids.
  defp list_tenancy_streams do
    Arrears
    |> Ash.read!()
    |> Enum.sort_by(& &1.tenancy_id)
    |> Enum.map(fn %Arrears{} = row ->
      %{
        id: "tenancy-" <> row.tenancy_id,
        label: row.tenancy_id,
        status: row.status,
        tone: tone_for(row)
      }
    end)
  end

  # A small at-a-glance tone for the nav dot — not the canonical arrears rule
  # (that stays in domain-model.md, linked from the deep panes in a later slice).
  defp tone_for(%Arrears{status: status}) when status in [:ending, :terminal], do: :info

  defp tone_for(%Arrears{} = row) do
    cond do
      Arrears.days_behind(row) >= 14 -> :crit
      (row.balance_cents || 0) > 0 -> :warn
      true -> :ok
    end
  end

  # The context that owns `stream_id`, or nil if no live stream matches. Streams
  # are enumerated at mount, so this is an exact membership check — not a guess.
  defp owning_context(contexts, stream_id) do
    Enum.find(contexts, fn ctx -> Enum.any?(ctx.streams, &(&1.id == stream_id)) end)
  end
end
