defmodule LatchkeyWeb.InspectorLive do
  @moduledoc """
  Root LiveView for the read-only ES/DDD **inspector** (spec developer-view.md,
  decisions D2/D3/D6).

  This slice is the **web spine**: the public `/inspector` route, the Workbench
  shell (nav rail · content · firehose placeholder), and the orientation-map
  landing. Deeper slices hang the three-pane fold, the replay scrubber, and the
  live firehose off this shell.

  Strictly read-only: it navigates and renders domain-event data. It issues no
  commands and exposes no create/update/delete affordance. The log is
  append-only / immutable.
  """
  use LatchkeyWeb, :live_view

  import LatchkeyWeb.InspectorComponents

  alias Latchkey.PropertyManagement.Arrears

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

    socket =
      socket
      |> assign(:contexts, contexts)
      |> assign(:tenancy_context, tenancy_context)
      |> assign(:accounts_context, @accounts_context)
      |> assign(:named_contexts, @named_contexts)
      |> assign(:acl_edge_label, @acl_edge_label)
      |> assign(:docs, @docs)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :landing, _params) do
    socket
    |> assign(:page_title, "Inspector — orientation")
    |> assign(:active_stream, nil)
  end

  defp apply_action(socket, :stream, %{"stream_id" => stream_id}) do
    socket
    |> assign(:page_title, "Inspector — #{stream_id}")
    |> assign(:active_stream, stream_id)
    |> assign(:context_name, context_name_for(stream_id))
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
            <%= if @live_action == :stream do %>
              <nav id="inspector-breadcrumb" class="mb-4 text-xs text-base-content/50">
                <.link patch={~p"/inspector"} class="hover:text-base-content">Contexts</.link>
                <span aria-hidden="true">/</span>
                <span class="text-base-content">{@context_name}</span>
                <span aria-hidden="true">/</span>
                <span class="font-mono text-base-content">{@active_stream}</span>
              </nav>
              <.stream_placeholder stream_id={@active_stream} context_name={@context_name} />
            <% else %>
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
            <.firehose_placeholder />
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

  defp context_name_for("accounts"), do: @accounts_context.name
  defp context_name_for(_stream_id), do: @tenancy_context_base.name
end
