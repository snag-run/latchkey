defmodule LatchkeyWeb.Inspector.GuidedStream do
  @moduledoc """
  The deep-stream layout for the inspector: a **numbered fold pipeline** with an
  optional **guided tour** overlaid on it.

  The resting layout is a single top-to-bottom column that makes the derives-from
  direction explicit — "① the log ▼ folds into ② replay ▼ ③ write & read model ▼
  ④ ledger" — so a newcomer can see that everything on the page is one fold of one
  append-only log, in reading order.

  On top of that sits an opt-in guided tour: a **Guided tour** button at the top
  starts it, dimming every stage but one and narrating it in a fixed card that
  scrolls the active stage into view; **Skip** / **✕** / **Done** leave the tour
  and reveal the plain pipeline. The tour is server-driven — its whole state is
  `tour_active?` + the `tour_step` index — and reuses the very same panes the
  layout already renders (`events_pane`, `scrubber`, `fold_panes`, `ledger_pane`),
  so it can never drift from what the page actually shows.

  All read-only: it re-arranges and narrates existing panes, issues no commands.
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.Inspector.EventLog
  import LatchkeyWeb.Inspector.Scrubber
  import LatchkeyWeb.Inspector.StatePanes
  import LatchkeyWeb.Inspector.LedgerPane

  # Ordered narration for the guided tour. Each stop lights up the pipeline stage
  # with the matching `tour-stage-N` id and lands one idea about the fold.
  @tour_stops [
    %{
      title: "① The log — the source of truth",
      body:
        "Every row is an immutable fact, in the order it happened. Nothing else on this page is stored — it is all recomputed from these events. Append-only: corrections are new events, never edits."
    },
    %{
      title: "② The fold — replay the log",
      body:
        "Drag to fold the log event-by-event. Each position recomputes every stage below as-of that prefix, server-side, using the very same fold production runs."
    },
    %{
      title: "③ Write vs read model — two folds of one log",
      body:
        "The aggregate (write model) guards the invariants; the read model is a disposable projection for reporting. Both fold the same events — and the consistency check proves they agree."
    },
    %{
      title: "④ The ledger — the same events, as money",
      body:
        "The identical events viewed as double-entry accounting. Debits and credits whose running balance equals the read model's balance, by construction — not by a second calculation."
    }
  ]

  @doc "Number of tour stops (one per pipeline stage)."
  def stops_count, do: length(@tour_stops)

  attr :tour_active?, :boolean, required: true
  attr :tour_step, :integer, required: true
  attr :active_stream, :string, required: true
  attr :context_name, :string, required: true
  attr :event_rows, :list, required: true
  attr :docs, :map, required: true
  attr :highlight_version, :integer, default: nil
  attr :scrubber_k, :integer, required: true
  attr :scrubber_n, :integer, required: true
  attr :scrubber_playing?, :boolean, required: true
  attr :new_events_available?, :boolean, required: true
  attr :aggregate_state, :map, required: true
  attr :read_model, :map, required: true
  attr :consistency, :any, required: true
  attr :ledger_entries, :list, required: true

  @doc "The deep-stream body: numbered fold pipeline + opt-in guided tour."
  def deep_stream(assigns) do
    ~H"""
    <.tour_launcher tour_active?={@tour_active?} />

    <div class={["max-w-2xl mx-auto space-y-2", @tour_active? && "pb-40"]}>
      <.flow_stage
        n="1"
        tour_active?={@tour_active?}
        step={0}
        title="The log"
        tag="source of truth"
        active?={@tour_step == 0}
      >
        <.spotlight tour_active?={@tour_active?} active?={@tour_step == 0} step={0}>
          <.events_pane
            stream_id={@active_stream}
            context_name={@context_name}
            kind={:deep}
            rows={@event_rows}
            docs={@docs}
            highlight_version={@highlight_version}
          />
        </.spotlight>
      </.flow_stage>

      <.flow_connector label="fold the events…" />

      <.flow_stage
        n="2"
        tour_active?={@tour_active?}
        step={1}
        title="Replay"
        tag="scrub the fold"
        active?={@tour_step == 1}
      >
        <.spotlight tour_active?={@tour_active?} active?={@tour_step == 1} step={1}>
          <.scrubber
            k={@scrubber_k}
            n={@scrubber_n}
            playing?={@scrubber_playing?}
            new_events_available?={@new_events_available?}
            docs={@docs}
          />
        </.spotlight>
      </.flow_stage>

      <.flow_connector label="…into state" />

      <.flow_stage
        n="3"
        step={2}
        title="Write & read model"
        tag="two folds, one log"
        tour_active?={@tour_active?}
        active?={@tour_step == 2}
      >
        <.spotlight tour_active?={@tour_active?} active?={@tour_step == 2} step={2}>
          <.fold_panes
            stream_id={@active_stream}
            state={@aggregate_state}
            derived={@read_model}
            consistency={@consistency}
            docs={@docs}
          />
        </.spotlight>
      </.flow_stage>

      <.flow_connector label="…and the same fold, as money" />

      <.flow_stage
        n="4"
        tour_active?={@tour_active?}
        step={3}
        title="Ledger"
        tag="double-entry"
        active?={@tour_step == 3}
      >
        <.spotlight tour_active?={@tour_active?} active?={@tour_step == 3} step={3}>
          <.ledger_pane
            stream_id={@active_stream}
            entries={@ledger_entries}
            read_model_balance_cents={@read_model.balance_cents}
            docs={@docs}
          />
        </.spotlight>
      </.flow_stage>
    </div>

    <.tour_narration tour_active?={@tour_active?} tour_step={@tour_step} />
    """
  end

  # ── Pipeline chrome ─────────────────────────────────────────────────────────

  attr :n, :string, required: true
  attr :step, :integer, required: true
  attr :title, :string, required: true
  attr :tag, :string, required: true
  attr :tour_active?, :boolean, default: false
  attr :active?, :boolean, default: false
  slot :inner_block, required: true

  defp flow_stage(assigns) do
    ~H"""
    <section id={"tour-stage-#{@step}"} class="min-w-0 scroll-mt-24">
      <div class="flex items-center gap-3 mb-3">
        <%!-- Outside the tour every stage reads as orange (no "current" step); --%>
        <%!-- during the tour only the active stage's badge is orange. --%>
        <span class={[
          "flex h-7 w-7 shrink-0 items-center justify-center rounded-full text-sm font-semibold transition-colors",
          if(!@tour_active? or @active?,
            do: "bg-orange-500 text-white",
            else: "bg-base-300 text-base-content/70"
          )
        ]}>
          {@n}
        </span>
        <h3 class="text-sm font-semibold text-base-content">{@title}</h3>
        <span class="text-[11px] uppercase tracking-wide text-base-content/40">{@tag}</span>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, required: true

  defp flow_connector(assigns) do
    ~H"""
    <div class="flex items-center gap-2 py-1 pl-3 text-xs text-base-content/40">
      <span class="text-lg leading-none">▼</span>
      <span class="italic">{@label}</span>
    </div>
    """
  end

  # ── Guided-tour overlay ─────────────────────────────────────────────────────

  attr :tour_active?, :boolean, required: true
  attr :active?, :boolean, required: true
  attr :step, :integer, required: true
  slot :inner_block, required: true

  # Wraps a pipeline stage: a highlight ring when it is the active tour step, a
  # dim when the tour is running on a different step, and plain otherwise.
  defp spotlight(assigns) do
    ~H"""
    <div class={[
      "transition-all duration-300 rounded-xl",
      @tour_active? && @active? && "ring-2 ring-orange-400 ring-offset-4 ring-offset-base-200",
      @tour_active? && !@active? && "opacity-30 blur-[1px]"
    ]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :tour_active?, :boolean, required: true

  # The top strip: a prompt + the button that starts (or restarts) the tour.
  defp tour_launcher(assigns) do
    ~H"""
    <div class="flex items-center justify-between mb-4">
      <p class="text-xs text-base-content/50">
        {if @tour_active?, do: "Guided tour in progress", else: "New here? Take the guided tour."}
      </p>
      <button
        type="button"
        id="tour-start"
        phx-click="tour_start"
        class="inline-flex items-center gap-1.5 rounded-md border border-orange-300 px-3 py-1.5
               text-xs font-medium text-orange-600 hover:bg-orange-500/10"
      >
        <span aria-hidden="true">{if @tour_active?, do: "↻", else: "▶"}</span>
        {if @tour_active?, do: "Restart tour", else: "Guided tour"}
      </button>
    </div>
    """
  end

  attr :tour_active?, :boolean, required: true
  attr :tour_step, :integer, required: true

  # The fixed narration card, shown only while the tour runs. It names the active
  # stage, narrates it, and scrolls that stage into view on each step (`.TourScroll`).
  defp tour_narration(assigns) do
    assigns =
      assigns
      |> assign(:stop, Enum.at(@tour_stops, assigns.tour_step))
      |> assign(:stops_count, length(@tour_stops))
      |> assign(:last_step?, assigns.tour_step == length(@tour_stops) - 1)

    ~H"""
    <div
      :if={@tour_active?}
      id="tour-narration"
      phx-hook=".TourScroll"
      data-target={"tour-stage-#{@tour_step}"}
      class="fixed bottom-6 left-1/2 -translate-x-1/2 z-40 w-[36rem] max-w-[calc(100vw-2rem)]
             rounded-xl border border-orange-300 bg-base-100 shadow-2xl p-5"
    >
      <button
        type="button"
        phx-click="tour_exit"
        aria-label="Close tour"
        class="absolute top-3 right-3 text-base-content/40 hover:text-base-content"
      >
        ✕
      </button>
      <p class="text-sm font-semibold text-orange-600 pr-6">{@stop.title}</p>
      <p class="mt-1 text-sm text-base-content/70 leading-relaxed">{@stop.body}</p>
      <div class="mt-4 flex items-center justify-between">
        <button
          type="button"
          id="tour-skip"
          phx-click="tour_exit"
          class="text-xs text-base-content/40 hover:text-base-content"
        >
          Skip tour
        </button>
        <div class="flex items-center gap-3">
          <button
            type="button"
            id="tour-back"
            phx-click="tour_step"
            phx-value-dir="prev"
            phx-value-max={@stops_count}
            disabled={@tour_step == 0}
            class="px-3 py-1.5 text-xs rounded-md border border-base-300 disabled:opacity-30 hover:bg-base-200"
          >
            ← Back
          </button>
          <span id="tour-progress" class="text-xs text-base-content/40">
            {@tour_step + 1} / {@stops_count}
          </span>
          <button
            :if={!@last_step?}
            type="button"
            id="tour-next"
            phx-click="tour_step"
            phx-value-dir="next"
            phx-value-max={@stops_count}
            class="px-3 py-1.5 text-xs rounded-md bg-orange-500 text-white hover:bg-orange-600"
          >
            Next →
          </button>
          <button
            :if={@last_step?}
            type="button"
            id="tour-done"
            phx-click="tour_exit"
            class="px-3 py-1.5 text-xs rounded-md bg-orange-500 text-white hover:bg-orange-600"
          >
            Done ✓
          </button>
        </div>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".TourScroll">
        export default {
          mounted() { this.scrollToTarget() },
          updated() { this.scrollToTarget() },
          scrollToTarget() {
            const el = document.getElementById(this.el.dataset.target)
            if (el) el.scrollIntoView({ behavior: "smooth", block: "center" })
          }
        }
      </script>
    </div>
    """
  end
end
