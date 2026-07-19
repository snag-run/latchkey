defmodule LatchkeyWeb.Inspector.Filmstrip do
  @moduledoc """
  The **event section** of the deep (tenancy) stream view, in the editorial
  "stream-detail" language (spec `docs/spec/developer-view.md` D4, issues #85/#86).

  It is the log *and* the replay scrubber in one, with two lenses over the same
  append-only log and the same prefix `k`:

  - the **horizontal filmstrip** (`filmstrip/1`) — the narrative lens: a spine of
    type-coloured node frames (type / date / signed amount), the frame *is* the
    scrubber (click to fold up to it), future frames dimmed, the frame at `k` lifted
    and `aria-current` (the fold-flow animation pulses it);
  - the **vertical evidence log** (`LatchkeyWeb.Inspector.EventLog.vertical_log/1`) —
    the full-detail lens with payloads, both envelope dates and divergence flags.

  A shared **transport** (step / play-pause / jump-to-head) and a **view toggle**
  sit above whichever lens is showing. Every control just moves `k` (or flips the
  lens); the LiveView recomputes the downstream panes via the **one shared fold**
  (`ArrearsFold` / `Timeline.fold`) — **no JS re-implementation** (D4). Reuses the
  same server events the range scrubber emitted (`scrub`, `step_back`,
  `step_forward`, `toggle_play`, `jump_to_head`) plus `toggle_event_view`.

  Presentational only — no create/update/delete affordance, reads/writes no store;
  the log is **append-only / immutable** (brief cut #4).
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.Inspector.EventLog, only: [vertical_log: 1]

  @doc """
  The deep stream's event section: transport + view toggle + the current lens.
  `view` is `:horizontal` (filmstrip) or `:vertical` (evidence log).
  """
  attr :stream_id, :string, required: true
  attr :context_name, :string, required: true
  attr :rows, :list, required: true, doc: "pre-resolved event rows in commit order"
  attr :k, :integer, required: true, doc: "current prefix length (0..n)"
  attr :n, :integer, required: true, doc: "event count (head position)"
  attr :playing?, :boolean, required: true, doc: "server-side auto-advance running?"
  attr :view, :atom, required: true, doc: ":horizontal (filmstrip) or :vertical (log)"

  attr :highlight_version, :integer,
    default: nil,
    doc: "stream_version of the event at the current prefix, or nil at k = 0"

  attr :new_events_available?, :boolean,
    default: false,
    doc: "live events landed while parked mid-history (D5) — shows the jump-to-head nudge"

  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"

  def event_section(assigns) do
    ~H"""
    <section id="replay-scrubber">
      <div class="sd-transport">
        <button
          id="scrubber-step-back"
          type="button"
          phx-click="step_back"
          disabled={@k <= 0}
          aria-label="Step back one event"
          class="sd-btn"
        >
          ‹ step
        </button>
        <button
          id="scrubber-play-toggle"
          type="button"
          phx-click="toggle_play"
          aria-pressed={to_string(@playing?)}
          aria-label={if(@playing?, do: "Pause replay", else: "Play replay")}
          class="sd-btn sd-primary"
        >
          {if @playing?, do: "❚❚ Pause", else: "▶ Play"}
        </button>
        <button
          id="scrubber-step-forward"
          type="button"
          phx-click="step_forward"
          disabled={@k >= @n}
          aria-label="Step forward one event"
          class="sd-btn"
        >
          step ›
        </button>

        <div id="event-view-toggle" class="sd-toggle" role="group" aria-label="Event view">
          <button
            id="event-view-horizontal"
            type="button"
            phx-click="set_event_view"
            phx-value-view="horizontal"
            aria-pressed={to_string(@view == :horizontal)}
          >
            ▭ Filmstrip
          </button>
          <button
            id="event-view-vertical"
            type="button"
            phx-click="set_event_view"
            phx-value-view="vertical"
            aria-pressed={to_string(@view == :vertical)}
          >
            ▤ Full log
          </button>
        </div>

        <span id="scrubber-position" class="sd-pos sd-mono">event {@k} / {@n}</span>
      </div>

      <%!-- Follow-at-head / pin-when-parked (spec D5, issue #86): parked mid-history --%>
      <%!-- while new events land live, the position holds and this nudge jumps to head. --%>
      <div
        :if={@new_events_available?}
        id="scrubber-nudge"
        role="status"
        class="sd-consist"
        style="margin-top:0"
      >
        <span class="sd-ck" style="background:var(--sd-accent)">↧</span>
        <span>New events landed on this stream while you're parked mid-history.</span>
        <button
          id="scrubber-jump-to-head"
          type="button"
          phx-click="jump_to_head"
          class="sd-btn"
          style="margin-left:auto"
        >
          Jump to head ›
        </button>
      </div>

      <p id="scrubber-caption" class="sd-note">
        Each frame is one event; the strip <b>is</b>
        the scrubber. Click a frame — or press <b>play</b>
        — to <b>fold</b>
        the log up to that point. The panes below rebuild as-of the first
        <code class="sd-mono">k</code>
        events, computed <b>server-side by the same fold</b>
        production runs. Nothing is edited; the log is <b>append-only / immutable</b>.
        <.link navigate={"#{@docs.domain_model}#4-the-tenancy-aggregate"} class="sd-readmore">
          domain-model.md §4
        </.link>
      </p>

      <%= if @view == :horizontal do %>
        <.filmstrip
          stream_id={@stream_id}
          rows={@rows}
          k={@k}
          n={@n}
          highlight_version={@highlight_version}
        />
      <% else %>
        <.vertical_log
          stream_id={@stream_id}
          context_name={@context_name}
          kind={:deep}
          rows={@rows}
          docs={@docs}
          scrubbable?={true}
          k={@k}
          highlight_version={@highlight_version}
        />
      <% end %>
    </section>
    """
  end

  @doc "The horizontal filmstrip spine — the narrative lens over the log."
  attr :stream_id, :string, required: true
  attr :rows, :list, required: true
  attr :k, :integer, required: true
  attr :n, :integer, required: true
  attr :highlight_version, :integer, default: nil

  def filmstrip(assigns) do
    ~H"""
    <div id="filmstrip-frames" class="sd-film" phx-hook=".FilmScroll">
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FilmScroll">
        // Keep the folded-to frame in view as the prefix moves (scrub / play / step),
        // scrolling this horizontal spine, not the page.
        export default {
          mounted() { this.follow() },
          updated() { this.follow() },
          follow() {
            const cur = this.el.querySelector('[aria-current="step"]')
            if (cur) cur.scrollIntoView({ behavior: "smooth", inline: "center", block: "nearest" })
          }
        }
      </script>
      <%!-- The empty prefix (k = 0): before any event has folded in. --%>
      <button
        id="scrubber-start"
        type="button"
        phx-click="scrub"
        phx-value-k="0"
        aria-label="Rewind to before any event"
        class={["sd-frame sd-first", @k > 0 && "sd-dim", @k == 0 && "sd-here"]}
      >
        <div class="sd-rail"></div>
        <div class="sd-node" style="background:var(--sd-axis)"></div>
        <div class="sd-card">
          <div class="sd-etype">∅ start</div>
          <div class="sd-edate">empty prefix</div>
        </div>
      </button>

      <button
        :for={row <- @rows}
        id={"event-row-#{@stream_id}-#{row.version}"}
        type="button"
        phx-click="scrub"
        phx-value-k={row.version}
        aria-current={row.version == @highlight_version && "step"}
        aria-label={"Fold up to event #{row.version}: #{row.type}"}
        class={[
          "sd-frame",
          row.version == @n && "sd-last",
          row.version > @k && "sd-dim",
          row.version == @highlight_version && "sd-here"
        ]}
      >
        <div class="sd-rail"></div>
        <div class="sd-node" style={"background:#{frame_color(row.type)}"}></div>
        <div class="sd-card">
          <div class="sd-etype">{row.type}</div>
          <div class="sd-edate">{fmt_date(row.occurred_on)}</div>
          <div
            :if={amount_cents(row.payload)}
            class={["sd-eamt", amount_class(row.type)]}
          >
            {amount_sign(row.type)}{money(amount_cents(row.payload))}
          </div>
        </div>
      </button>
    </div>
    """
  end

  # A frame's node colour by event type — the sweep of a tenancy's life at a glance.
  defp frame_color("TenancyCommenced"), do: "var(--sd-write)"
  defp frame_color("RentFellDue"), do: "var(--sd-debit)"
  defp frame_color("RentPaymentRecorded"), do: "var(--sd-credit)"
  defp frame_color("TerminationNoticeGiven"), do: "var(--sd-accent)"
  defp frame_color("KeysReturned"), do: "var(--sd-accent)"
  defp frame_color("TenancySettled"), do: "var(--sd-muted)"
  defp frame_color(_type), do: "var(--sd-axis)"

  # A charge adds to the balance (debit, "+"); a payment reduces it (credit, "−").
  defp amount_class("RentFellDue"), do: "sd-deb"
  defp amount_class("RentPaymentRecorded"), do: "sd-cre"
  defp amount_class(_type), do: nil

  defp amount_sign("RentFellDue"), do: "+"
  defp amount_sign("RentPaymentRecorded"), do: "−"
  defp amount_sign(_type), do: ""

  # A charge / payment carries `:amount_cents`; lifecycle events carry none.
  defp amount_cents(payload) do
    case List.keyfind(payload, :amount_cents, 0) do
      {:amount_cents, cents} when is_integer(cents) -> cents
      _ -> nil
    end
  end

  defp fmt_date(%Date{} = d), do: Date.to_iso8601(d)
  defp fmt_date(_), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)
    dollars = div(abs_cents, 100)
    remainder = rem(abs_cents, 100)
    "#{sign}$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end
end
