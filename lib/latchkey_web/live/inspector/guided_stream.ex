defmodule LatchkeyWeb.Inspector.GuidedStream do
  @moduledoc """
  The deep-stream layout for the inspector, in the editorial "stream-detail"
  language: a single stage card that makes the derives-from direction explicit —
  **the log (a horizontal filmstrip that is itself the scrubber, or a vertical
  evidence log) ▽ folds into the write & read models ▽ folds into the ledger** — so
  a newcomer can see that everything on the page is one fold of one append-only log.

  The event section offers two lenses over the same log and prefix: the horizontal
  **filmstrip** (narrative) and the vertical **evidence log** (full payloads +
  divergence flags), flipped with a view toggle.

  On top of that sits an opt-in **guided tour**: a launcher starts it, dimming every
  stage but one and narrating it in a fixed card that scrolls the active stage into
  view; Skip / ✕ / Done leave it. The tour is server-driven — its whole state is
  `tour_active?` + the `tour_step` index — and reuses the very same panes the layout
  already renders (`event_section`, `fold_panes`, `ledger_pane`), so it can never
  drift from what the page actually shows.

  All read-only: it re-arranges and narrates existing panes, issues no commands.
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.Inspector.Filmstrip, only: [event_section: 1]
  import LatchkeyWeb.Inspector.StatePanes, only: [fold_panes: 1]
  import LatchkeyWeb.Inspector.LedgerPane, only: [ledger_pane: 1]

  # Ordered narration for the guided tour. Each stop lights up the stage with the
  # matching `tour-stage-N` id and lands one idea about the fold.
  @tour_stops [
    %{
      title: "① The log — replay the fold",
      body:
        "Every frame is one immutable fact, in the order it happened. The strip is the source of truth — nothing else on this page is stored, it is all recomputed. Click a frame or press play to fold the log up to that point, event by event, server-side. Flip to the full log for payloads and divergence flags."
    },
    %{
      title: "② Write vs read — two folds, do they agree?",
      body:
        "The aggregate (write model) guards the invariants; the read model is a disposable projection for reporting. Both fold the same events — and the consistency check between them, the seam, proves they agree."
    },
    %{
      title: "③ The ledger — the same events, as money",
      body:
        "The identical events viewed through an independent double-entry fold. Debits and credits whose running balance equals the read model's balance by construction."
    }
  ]

  @doc "Number of tour stops (one per stage)."
  def stops_count, do: length(@tour_stops)

  attr :tour_active?, :boolean, required: true
  attr :tour_step, :integer, required: true
  attr :active_stream, :string, required: true
  attr :context_name, :string, required: true
  attr :event_rows, :list, required: true
  attr :event_view, :atom, required: true, doc: ":horizontal (filmstrip) or :vertical (log)"
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

  @doc "The deep-stream body: the editorial fold stage + opt-in guided tour."
  def deep_stream(assigns) do
    ~H"""
    <div id="fold-flow" class="stream-detail" phx-hook=".FoldFlow" data-stream={@active_stream}>
      <p class="sd-eyebrow">Tenancy stream · the fold, made visible</p>
      <h1 class="sd-h1">Write vs read — two folds, do they agree?</h1>
      <p class="sd-lede">
        The event log is a horizontal filmstrip that doubles as the scrubber. Below, the
        same prefix folds into the write model and the read model — facing each other,
        with the consistency check as the seam — then into the ledger, the same events as
        money.
      </p>
      <p class="sd-streamid">
        stream <b class="sd-mono">{@active_stream}</b>
        <span aria-hidden="true">·</span>
        {@context_name}
      </p>

      <.tour_launcher tour_active?={@tour_active?} />

      <div class={["sd-stage", @tour_active? && "pb-40"]}>
        <section id="tour-stage-0" style="scroll-margin-top:6rem">
          <.spotlight tour_active?={@tour_active?} active?={@tour_step == 0} step={0}>
            <.event_section
              stream_id={@active_stream}
              context_name={@context_name}
              rows={@event_rows}
              k={@scrubber_k}
              n={@scrubber_n}
              playing?={@scrubber_playing?}
              view={@event_view}
              highlight_version={@highlight_version}
              new_events_available?={@new_events_available?}
              docs={@docs}
            />
          </.spotlight>
        </section>

        <div class="sd-foldlabel">
          <span data-fold-connector>▽</span>
          the folded prefix derives <span data-fold-connector>▽</span>
        </div>

        <section id="tour-stage-1" style="scroll-margin-top:6rem">
          <.spotlight tour_active?={@tour_active?} active?={@tour_step == 1} step={1}>
            <.fold_panes
              stream_id={@active_stream}
              state={@aggregate_state}
              derived={@read_model}
              consistency={@consistency}
              docs={@docs}
            />
          </.spotlight>
        </section>

        <div class="sd-foldlabel">
          <span data-fold-connector>▽</span>
          the same events, as money <span data-fold-connector>▽</span>
        </div>

        <section id="tour-stage-2" style="scroll-margin-top:6rem">
          <.spotlight tour_active?={@tour_active?} active?={@tour_step == 2} step={2}>
            <.ledger_pane
              stream_id={@active_stream}
              entries={@ledger_entries}
              read_model_balance_cents={@read_model.balance_cents}
              docs={@docs}
            />
          </.spotlight>
        </section>
      </div>

      <.tour_narration tour_active?={@tour_active?} tour_step={@tour_step} />

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FoldFlow">
        // Choreographs the "fold": when the server advances the scrubber prefix it
        // pushes "fold:flow", and this hook plays the causality — the folded-in event
        // pulses, the pulse runs down the pipeline connectors, and the state/read-model
        // fields that actually changed flash (numeric headline fields count to value).
        // Purely presentational: the server has already re-rendered the real panes.
        export default {
          mounted() {
            this.stream = this.el.dataset.stream
            this.seed()
            this.handleEvent("fold:flow", (p) => this.run(p))
          },
          updated() {
            // Reseed only when the whole stream changes; on a fold patch the cache must
            // still hold the *previous* values so run() can diff against them.
            if (this.el.dataset.stream !== this.stream) {
              this.stream = this.el.dataset.stream
              this.seed()
            }
          },
          reduced() {
            return window.matchMedia("(prefers-reduced-motion: reduce)").matches
          },
          fields() {
            return Array.from(this.el.querySelectorAll("[data-fold-field]"))
          },
          seed() {
            this.cache = {}
            this.fields().forEach((el) => { this.cache[el.id] = el.textContent.trim() })
          },
          run(p) {
            const anime = window.anime
            if (!anime || this.reduced()) { this.seed(); return }
            const fwd = p.dir !== "back"

            // 1) the event that just folded in
            const row = this.el.querySelector('[aria-current="step"]')
            if (row) {
              anime.remove(row)
              anime({ targets: row, translateX: [fwd ? -8 : 8, 0], opacity: [0.55, 1],
                duration: 420, easing: "easeOutQuad" })
            }

            // 2) the pulse travelling down (or up) the pipeline
            const conns = Array.from(this.el.querySelectorAll("[data-fold-connector]"))
            if (conns.length) {
              anime.remove(conns)
              anime({ targets: conns,
                keyframes: [{ scale: 1, opacity: 0.35 }, { scale: 1.6, opacity: 1 }, { scale: 1, opacity: 0.35 }],
                delay: anime.stagger(90, { from: fwd ? "first" : "last" }),
                duration: 460, easing: "easeInOutSine" })
            }

            // 3) flash the fields that changed; count the numeric headline ones
            const lead = conns.length ? conns.length * 90 + 120 : 120
            this.fields().forEach((el) => {
              const now = el.textContent.trim()
              const was = this.cache[el.id]
              if (was !== undefined && was !== now) {
                this.flash(el, lead)
                if (el.hasAttribute("data-fold-count")) this.count(el, was, now, lead)
              }
              this.cache[el.id] = now
            })

            // 4) the newest ledger row (forward only — a back-step removes one)
            if (fwd) {
              const last = this.el.querySelector("#ledger-rows tr:last-child")
              if (last && !last.querySelector("[colspan]")) this.flash(last, lead + 80)
            }
          },
          flash(el, delay) {
            const anime = window.anime
            anime.remove(el)
            anime({ targets: el, backgroundColor: ["rgba(249,115,22,0.30)", "rgba(249,115,22,0)"],
              delay, duration: 900, easing: "easeOutQuad",
              complete: () => { el.style.backgroundColor = "" } })
          },
          count(el, was, now, delay) {
            const from = this.parse(was), to = this.parse(now)
            if (from === null || to === null) return
            const proxy = { v: from }
            window.anime({ targets: proxy, v: to, delay, duration: 620, easing: "easeOutExpo",
              update: () => { el.textContent = this.fmtLike(now, proxy.v) },
              complete: () => { el.textContent = now } })
          },
          parse(t) {
            const m = t.replace(/[^0-9.\-]/g, "")
            if (m === "" || m === "-" || m === ".") return null
            const n = parseFloat(m)
            return isNaN(n) ? null : n
          },
          fmtLike(sample, v) {
            if (/day/.test(sample)) return Math.round(v) + " days"
            if (sample.includes("$")) {
              const neg = v < 0
              return (neg ? "-$" : "$") + Math.abs(v).toFixed(2)
            }
            return String(Math.round(v))
          }
        }
      </script>
    </div>
    """
  end

  # ── Guided-tour chrome ──────────────────────────────────────────────────────

  attr :tour_active?, :boolean, required: true
  attr :active?, :boolean, required: true
  attr :step, :integer, required: true
  slot :inner_block, required: true

  # Wraps a stage: a highlight ring when it is the active tour step, a dim when the
  # tour is running on a different step, and plain otherwise.
  defp spotlight(assigns) do
    ~H"""
    <div class={[
      "transition-all duration-300 rounded-2xl",
      @tour_active? && @active? &&
        "ring-2 ring-[color:var(--sd-accent)] ring-offset-4 ring-offset-[color:var(--sd-surface)]",
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
    <div class="flex items-center justify-between mt-4 mb-1">
      <p class="sd-note" style="margin:0">
        {if @tour_active?, do: "Guided tour in progress", else: "New here? Take the guided tour."}
      </p>
      <button type="button" id="tour-start" phx-click="tour_start" class="sd-btn">
        {if @tour_active?, do: "↻ Restart tour", else: "▶ Guided tour"}
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
      class="stream-detail"
      phx-hook=".TourScroll"
      data-target={"tour-stage-#{@tour_step}"}
      style="position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:40;
             width:36rem;max-width:calc(100vw - 2rem);background:var(--sd-surface);
             border:1px solid var(--sd-accent);border-radius:14px;box-shadow:var(--sd-shadow);padding:18px 20px"
    >
      <button
        type="button"
        phx-click="tour_exit"
        aria-label="Close tour"
        style="position:absolute;top:12px;right:14px;color:var(--sd-muted);background:none;border:none;cursor:pointer"
      >
        ✕
      </button>
      <p style="font-weight:650;color:var(--sd-accent);margin:0;padding-right:24px">{@stop.title}</p>
      <p class="sd-lede" style="margin-top:4px;font-size:13.5px">{@stop.body}</p>
      <div class="sd-transport" style="margin:16px 0 0">
        <button type="button" id="tour-skip" phx-click="tour_exit" class="sd-btn">Skip tour</button>
        <span id="tour-progress" class="sd-pos">{@tour_step + 1} / {@stops_count}</span>
        <button
          type="button"
          id="tour-back"
          phx-click="tour_step"
          phx-value-dir="prev"
          disabled={@tour_step == 0}
          class="sd-btn"
        >
          ← Back
        </button>
        <button
          :if={!@last_step?}
          type="button"
          id="tour-next"
          phx-click="tour_step"
          phx-value-dir="next"
          class="sd-btn sd-primary"
        >
          Next →
        </button>
        <button
          :if={@last_step?}
          type="button"
          id="tour-done"
          phx-click="tour_exit"
          class="sd-btn sd-primary"
        >
          Done ✓
        </button>
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
