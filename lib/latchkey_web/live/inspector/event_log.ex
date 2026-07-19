defmodule LatchkeyWeb.Inspector.EventLog do
  @moduledoc """
  The read-only **vertical evidence log** — the full-detail lens on a stream's raw,
  immutable events (`LatchkeyWeb.InspectorLive`, spec `docs/spec/developer-view.md`
  D3/D7, issue #81). Rendered in the editorial "stream-detail" visual language.

  It is the **evidence** lens: unlike the horizontal filmstrip (the narrative lens,
  which shows only type + date + amount), each row here is **self-describing out of
  context** for the tribunal-evidence goal — the **property** (leading) and
  **tenant**, **both envelope dates** (`occurred_on` / `recorded_on`) with a visible
  **divergence flag** when they differ (D7), and the **full stored payload**.

  It serves two callers:

  - the **deep** (tenancy) stream, as the vertical toggle of the filmstrip — rows are
    dimmed past the current prefix and the row at `k` is highlighted + `aria-current`
    (so the fold-flow animation pulses it), and each row is a scrub target;
  - the **Accounts edge** (D3), events-only, captioned as an edge context that folds
    no aggregate state (no filmstrip, no scrub — the *absence* is the teaching point).

  Presentational only. It renders the pre-built rows it is handed — it reads no store,
  folds no state, and exposes **no** create/update/delete affordance. The log is
  **append-only / immutable** (never "tamper-evident" — issue #16).
  """
  use LatchkeyWeb, :html

  @doc """
  The vertical evidence log for one stream. `rows` are pre-resolved event rows in
  commit order. When `scrubbable?` (the deep stream), `k` dims rows past the prefix,
  `highlight_version` marks the current row, and rows are scrub targets; the edge
  passes `scrubbable?: false` (no dim, no highlight, no click).
  """
  attr :stream_id, :string, required: true
  attr :context_name, :string, required: true
  attr :kind, :atom, required: true, doc: ":deep (tenancy) or :edge (accounts)"
  attr :rows, :list, required: true, doc: "pre-resolved event rows in commit order"
  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"
  attr :scrubbable?, :boolean, default: false, doc: "deep streams scrub; the edge does not"
  attr :k, :integer, default: nil, doc: "current prefix length — dims rows past it (deep)"

  attr :highlight_version, :integer,
    default: nil,
    doc: "stream_version of the row at the current prefix (deep), else nil"

  def vertical_log(assigns) do
    ~H"""
    <section id="event-log">
      <p :if={@kind == :edge} id="accounts-edge-caption" class="sd-note">
        <b>Edge context.</b>
        Accounts emits payment facts and <b>folds no aggregate state</b>
        — so there is no aggregate or read-model pane here, only this raw log. The <i>absence</i>
        of those panes is the teaching point.
      </p>

      <p id="bitemporal-caption" class="sd-note">
        Every event carries two dates — <b>occurred_on</b>
        (when the fact became true) and <b>recorded_on</b>
        (when it was booked). When they diverge it is flagged: an imported/rebuilt
        tenancy or a forward-dated fact — organic accrual books same-day.
        <.link
          navigate={"#{@docs.domain_model}#3-events-producers"}
          class="sd-readmore"
        >
          domain-model.md §3
        </.link>
      </p>

      <p id="immutability-note" class="sd-note">
        This log is <b>append-only / immutable</b> — events are never edited or
        deleted; corrections are compensating appends.
      </p>

      <div id={"stream-view-#{@stream_id}"} class="sd-vlog" phx-hook=".LogScroll">
        <script :type={Phoenix.LiveView.ColocatedHook} name=".LogScroll">
          // Keep the folded-to row in view as the prefix moves, scrolling this log
          // pane (deep vertical lens); on the edge there is no current row, so no-op.
          export default {
            mounted() { this.follow() },
            updated() { this.follow() },
            follow() {
              const cur = this.el.querySelector('[aria-current="step"]')
              if (cur) cur.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" })
            }
          }
        </script>
        <p :if={@rows == []} id="event-log-empty" class="sd-note">
          No events on this stream yet.
        </p>

        <%= for row <- @rows do %>
          <% dimmed? = @scrubbable? and @k != nil and row.version > @k %>
          <% here? = row.version == @highlight_version %>
          <div
            id={"event-row-#{@stream_id}-#{row.version}"}
            aria-current={here? && "step"}
            phx-click={@scrubbable? && "scrub"}
            phx-value-k={@scrubbable? && row.version}
            role={@scrubbable? && "button"}
            tabindex={@scrubbable? && "0"}
            class={[
              "sd-vrow",
              @scrubbable? && "cursor-pointer",
              here? && "sd-here",
              dimmed? && "sd-dim"
            ]}
          >
            <div class="sd-vhead">
              <span class="sd-vtype">{row.type}</span>
              <span class="sd-vver">#{row.version}</span>
              <span
                :if={row.divergent?}
                id={"event-divergence-#{@stream_id}-#{row.version}"}
                class="sd-flag"
                title="occurred_on and recorded_on differ (bitemporal divergence)"
              >
                occurred ≠ recorded
              </span>
            </div>

            <p id={"event-identity-#{@stream_id}-#{row.version}"} class="sd-vident">
              <b>{row.identity.property}</b>
              <span aria-hidden="true">·</span>
              <span>{row.identity.tenant}</span>
              <span class="sd-mono" style="color:var(--sd-muted)">{row.identity.ref}</span>
            </p>

            <dl class="sd-payload">
              <dt>occurred_on</dt>
              <dd>{fmt(row.occurred_on)}</dd>
              <dt>recorded_on</dt>
              <dd class={[row.divergent? && "sd-diverge"]}>{fmt(row.recorded_on)}</dd>

              <div :for={{key, value} <- row.payload} class="contents">
                <dt>{key}</dt>
                <dd>{fmt(value)}</dd>
              </div>
            </dl>
          </div>
        <% end %>
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
