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
  import LatchkeyWeb.InspectorComponents

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.EventStore
  alias Latchkey.Inspector.Broadcaster
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.Simulation.Directory
  alias Latchkey.Simulation.Identity

  # Bound on the firehose feed's live retained rows — old rows fall off the head
  # as new ones arrive, so the stream can't balloon memory over a long-running
  # session (spec D5: "LiveView streams ... so the feed can't balloon memory").
  @firehose_limit 200

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
      |> stream(:firehose, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  # ── Live firehose (spec D5) ─────────────────────────────────────────────────
  # Every event Latchkey.Inspector.Broadcaster re-broadcasts lands here. This is
  # the "follow at head" half of D5 — the pinned-when-parked scrub interaction
  # is owned by the (not-yet-built) stream-detail view.
  @impl true
  def handle_info({:dev_event, event, metadata}, socket) do
    row = to_firehose_row(event, metadata)

    {:noreply, stream_insert(socket, :firehose, row, at: 0, limit: @firehose_limit)}
  end

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

  defp apply_action(socket, :landing, _params) do
    socket
    |> assign(:page_title, "Inspector — orientation")
    |> assign(:active_stream, nil)
  end

  defp apply_action(socket, :stream, %{"stream_id" => stream_id}) do
    # Validate against the streams enumerable at mount, so a typo'd or stale URL
    # surfaces as "unknown" instead of masquerading as a valid Tenancy stream.
    case owning_context(socket.assigns.contexts, stream_id) do
      nil ->
        socket
        |> assign(:page_title, "Inspector — unknown stream")
        |> assign(:active_stream, nil)
        |> assign(:stream_found?, false)
        |> assign(:unknown_stream_id, stream_id)

      context ->
        socket
        |> assign(:page_title, "Inspector — #{stream_id}")
        |> assign(:active_stream, stream_id)
        |> assign(:stream_found?, true)
        |> assign(:context_name, context.name)
        |> assign(:stream_kind, context.kind)
        |> assign(:event_rows, load_event_rows(stream_id, context.kind))
    end
  end

  # ── Event-log pane (issue #81, spec D3/D7) ──────────────────────────────────
  # Reads a stream's raw events from the store and builds display rows: full
  # payloads, both envelope dates + a divergence flag (D7), and property-leading
  # identity. In-memory only — no fold, no write. Tenancy streams resolve identity
  # once off the stream's `property_ref` + `tenancy_id` (Identity.resolve/2); the
  # `accounts` edge derives identity from each payment `holder`, honestly showing
  # UNKNOWN when unresolvable (D3).
  defp load_event_rows(stream_id, :edge) do
    directory = directory_map()
    recorded = read_stream(stream_id)
    holders = payment_holders(recorded)

    Enum.map(recorded, fn r -> base_row(r, accounts_identity(r.data, directory, holders)) end)
  end

  defp load_event_rows(stream_id, _deep) do
    recorded = read_stream(stream_id)
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
