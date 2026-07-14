defmodule LatchkeyWeb.Inspector.EventLog do
  @moduledoc """
  The read-only **event-log pane** (`LatchkeyWeb.InspectorLive`, spec
  `docs/spec/developer-view.md`, issue #81, decisions D3/D7): for a selected
  stream it renders the raw, immutable events in commit order with their **full
  stored payloads**.

  It doubles as the **Accounts edge** view (D3): the single `accounts` stream
  renders through this same pane, **events-only**, captioned as an edge context
  that folds no aggregate state (no aggregate / read-model panes, by design).

  Each row is **self-describing out of context** (the tribunal-evidence goal): it
  names the **property** (leading — the primary PM identifier) and **tenant**, and
  shows **both envelope dates** (`occurred_on` / `recorded_on`) with a visible
  **divergence flag** when they differ (D7 — for `RentFellDue`, an imported/rebuilt
  tenancy (#117), since organic accrual books same-day; or a forward-dated fact).
  Identity is resolved upstream in `LatchkeyWeb.InspectorLive`; accounts
  rows honestly show an `UNKNOWN` sentinel when the payment holder is unresolvable.

  Presentational only. It renders the pre-built rows it is handed — it reads no
  store, folds no state, and exposes **no** create/update/delete affordance. The
  log is **append-only / immutable** (never "tamper-evident" — issue #16).
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.InspectorComponents, only: [caption: 1, read_more: 1, glossary_ref: 1]

  @doc """
  The event-log pane for one stream. `rows` are the pre-resolved event rows (see
  `LatchkeyWeb.InspectorLive`), `kind` is `:deep` (a tenancy stream) or `:edge`
  (the `accounts` stream).
  """
  attr :stream_id, :string, required: true
  attr :context_name, :string, required: true
  attr :kind, :atom, required: true, doc: ":deep (tenancy) or :edge (accounts)"
  attr :rows, :list, required: true, doc: "pre-resolved event rows in commit order"

  attr :highlight_version, :integer,
    default: nil,
    doc: "stream_version of the replay scrubber's current event (D4), or nil when unscrubbed"

  def events_pane(assigns) do
    ~H"""
    <section id="event-log" class="max-w-3xl">
      <div id="stream-view">
        <div id={"stream-view-#{@stream_id}"}>
          <header class="mb-3">
            <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
              {@context_name} · events
            </p>
            <h2 class="mt-1 text-lg font-semibold font-mono">{@stream_id}</h2>
          </header>

          <%!-- Thin, interaction-anchored teaching captions (spec D2 altitude split). --%>
          <div class="mb-4 space-y-2">
            <.caption :if={@kind == :edge} id="accounts-edge-caption">
              <b>Edge context.</b>
              Accounts emits payment facts and <b>folds no aggregate state</b>
              —
              so there is no aggregate or read-model pane here, only this raw log. The <i>absence</i>
              of those panes is the teaching point.
            </.caption>

            <.caption id="bitemporal-caption">
              Every event carries two dates — <b>occurred_on</b>
              (when the fact became true) and <b>recorded_on</b>
              (when it was booked). When they diverge it is flagged: an
              imported/rebuilt tenancy or a forward-dated fact — organic accrual
              books same-day.
              <.read_more href={glossary_ref("Domain event")}>Domain event</.read_more>
            </.caption>

            <p id="immutability-note" class="text-xs leading-relaxed text-base-content/60">
              This log is <b class="text-base-content/80">append-only / immutable</b> — events are
              never edited or deleted; corrections are compensating appends.
            </p>
          </div>

          <ol id="event-log-rows" class="relative border-l border-base-300 ml-1.5">
            <li
              :if={@rows == []}
              id="event-log-empty"
              class="pl-5 py-3 text-xs text-base-content/50 italic"
            >
              No events on this stream yet.
            </li>

            <li
              :for={row <- @rows}
              id={"event-row-#{@stream_id}-#{row.version}"}
              aria-current={row.version == @highlight_version && "step"}
              class={[
                "relative pl-5 pb-5",
                row.version == @highlight_version &&
                  "-ml-px rounded-r-md border-l-2 border-accent bg-accent/5"
              ]}
            >
              <span
                class={[
                  "absolute -left-[5px] top-1.5 size-2.5 rounded-full",
                  if(row.version == @highlight_version, do: "bg-accent", else: "bg-primary")
                ]}
                aria-hidden="true"
              />

              <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
                <span class="font-mono text-sm font-semibold">{row.type}</span>
                <span class="font-mono text-[11px] text-base-content/40">#{row.version}</span>

                <span
                  :if={row.divergent?}
                  id={"event-divergence-#{@stream_id}-#{row.version}"}
                  class="badge badge-sm badge-warning gap-1"
                  title="occurred_on and recorded_on differ (bitemporal divergence)"
                >
                  occurred ≠ recorded
                </span>
              </div>

              <%!-- Property-leading identity line: self-describing out of context (#81). --%>
              <p
                id={"event-identity-#{@stream_id}-#{row.version}"}
                class="mt-0.5 text-[11px] text-base-content/60"
              >
                <span class="font-medium text-base-content/80">{row.identity.property}</span>
                <span aria-hidden="true">·</span>
                <span>{row.identity.tenant}</span>
                <span class="font-mono text-base-content/40">{row.identity.ref}</span>
              </p>

              <%!-- Two-date bitemporal display (D7). --%>
              <dl class="mt-1.5 grid grid-cols-[auto_1fr] gap-x-3 text-[11px]">
                <dt class="text-base-content/50">occurred_on</dt>
                <dd class="font-mono">{fmt(row.occurred_on)}</dd>
                <dt class="text-base-content/50">recorded_on</dt>
                <dd class={["font-mono", row.divergent? && "text-warning"]}>
                  {fmt(row.recorded_on)}
                </dd>
              </dl>

              <%!-- Full stored payload. --%>
              <dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 rounded-lg bg-base-200/60 p-2.5 text-[11px]">
                <div :for={{key, value} <- row.payload} class="contents">
                  <dt class="font-mono text-base-content/50">{key}</dt>
                  <dd class="font-mono break-all">{fmt(value)}</dd>
                </div>
              </dl>
            </li>
          </ol>
        </div>
      </div>
    </section>
    """
  end

  # Render a stored payload value (dates, atoms, ints, strings, nils) for display.
  defp fmt(%Date{} = d), do: Date.to_iso8601(d)
  defp fmt(nil), do: "—"
  defp fmt(value) when is_binary(value), do: value
  defp fmt(value) when is_atom(value), do: Atom.to_string(value)
  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value), do: inspect(value)
end
