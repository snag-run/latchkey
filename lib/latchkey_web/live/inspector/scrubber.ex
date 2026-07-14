defmodule LatchkeyWeb.Inspector.Scrubber do
  @moduledoc """
  The read-only **server-side replay scrubber** — the centerpiece of the tenancy
  stream-detail view (`LatchkeyWeb.InspectorLive`, spec `docs/spec/developer-view.md`
  decision **D4**, issue #85): watch the aggregate, read model and ledger fold, event
  by event.

  The scrubber's whole state is one integer **`k`** — a **prefix length** over `0..N`
  (`N` = the stream's event count). `k = 0` is the empty prefix (before any event);
  `k = N` is the head (all events). Every control just moves `k`; the LiveView then
  recomputes all four panes as-of the first `k` events via the **one shared fold**
  (`Latchkey.PropertyManagement.ArrearsFold` / `Timeline.fold/1`), so the fold you
  watch is the very one production runs — **no JS re-implementation** (D4).

  `days_behind` is reckoned **as-at the prefix's last event `occurred_on`** (D1), so
  arrears visibly climb and fall through the scrub rather than always reading "today".

  This is a presentational component: it renders the controls and emits `scrub`,
  `step_back`, `step_forward` and `toggle_play` events the host LiveView handles
  entirely **server-side** (play/pause is a self-scheduled server tick, not a client
  timer). It exposes **no** create/update/delete affordance and reads/writes no store —
  the log is **append-only / immutable**; the scrubber only folds a selected prefix of
  already-read events in memory (brief cut #4).

  Only tenancy (`:deep`) streams carry a scrubber; the Accounts (`:edge`) stream is
  events-only, so it renders no scrubber at all (D3/D4).
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.InspectorComponents, only: [caption: 1, read_more: 1, glossary_ref: 1]

  @doc """
  The replay-scrubber controls for one tenancy stream. `k` is the current prefix
  length (`0..n`), `n` the stream's event count, and `playing?` whether the
  server-side auto-advance tick is running.
  """
  attr :k, :integer, required: true, doc: "current prefix length (0..n)"
  attr :n, :integer, required: true, doc: "event count (head position)"
  attr :playing?, :boolean, required: true, doc: "server-side auto-advance running?"

  attr :new_events_available?, :boolean,
    default: false,
    doc: "live events landed while parked mid-history (D5) — shows the jump-to-head nudge"

  def scrubber(assigns) do
    ~H"""
    <section
      id="replay-scrubber"
      class="mt-6 max-w-3xl rounded-xl border border-accent/50 bg-base-100 p-4"
    >
      <header class="mb-2 flex items-center gap-2">
        <span class="badge badge-sm badge-accent">replay</span>
        <h3 class="text-sm font-semibold">Fold scrubber</h3>
        <span id="scrubber-position" class="ml-auto font-mono text-[11px] text-base-content/50">
          {@k} / {@n}
        </span>
      </header>

      <%!-- Follow-at-head / pin-when-parked (spec D5, issue #86). Parked mid-history --%>
      <%!-- while new events land live, the position holds and this nudge offers a jump --%>
      <%!-- to the head, which folds them in and resumes following. --%>
      <div
        :if={@new_events_available?}
        id="scrubber-nudge"
        role="status"
        class="mb-3 flex items-center gap-2 rounded-lg border border-info/40 bg-info/10 px-3 py-2 text-xs"
      >
        <.icon name="hero-arrow-down-circle" class="size-4 shrink-0 text-info" />
        <span>New events landed on this stream while you're parked mid-history.</span>
        <button
          id="scrubber-jump-to-head"
          type="button"
          phx-click="jump_to_head"
          class="btn btn-xs btn-info ml-auto gap-1 transition-transform hover:scale-105"
        >
          Jump to head <.icon name="hero-arrow-right" class="size-3" />
        </button>
      </div>

      <.caption id="scrubber-caption" class="mb-3">
        Press <b>play</b>
        and watch the log <b>fold</b>
        into state. Position <code class="font-mono">k</code>
        is a prefix length — the panes below rebuild as-of the first <code class="font-mono">k</code>
        events, computed <b>server-side by the same fold</b>
        production runs. Nothing is edited; the log is <b>append-only / immutable</b>, and this
        is an in-memory fold over a selected prefix.
        <.read_more href={glossary_ref("Replay")}>Replay</.read_more>
      </.caption>

      <div class="flex items-center gap-2">
        <button
          id="scrubber-step-back"
          type="button"
          phx-click="step_back"
          disabled={@k <= 0}
          aria-label="Step back one event"
          class="btn btn-xs btn-ghost disabled:opacity-30"
        >
          <.icon name="hero-chevron-left" class="size-4" />
        </button>

        <button
          id="scrubber-play-toggle"
          type="button"
          phx-click="toggle_play"
          aria-pressed={to_string(@playing?)}
          aria-label={if(@playing?, do: "Pause replay", else: "Play replay")}
          class="btn btn-xs btn-primary gap-1"
        >
          <%= if @playing? do %>
            <.icon name="hero-pause" class="size-4" />
            <span>Pause</span>
          <% else %>
            <.icon name="hero-play" class="size-4" />
            <span>Play</span>
          <% end %>
        </button>

        <button
          id="scrubber-step-forward"
          type="button"
          phx-click="step_forward"
          disabled={@k >= @n}
          aria-label="Step forward one event"
          class="btn btn-xs btn-ghost disabled:opacity-30"
        >
          <.icon name="hero-chevron-right" class="size-4" />
        </button>

        <%!-- Bare range input (no <form>): a lone input still emits phx-change with --%>
        <%!-- its name/value. The inspector is deliberately form-free — read-only, no --%>
        <%!-- command affordance anywhere (brief cut #1). --%>
        <input
          id="scrubber-slider"
          type="range"
          name="k"
          min="0"
          max={@n}
          value={@k}
          step="1"
          phx-change="scrub"
          aria-label="Replay position"
          class="range range-xs range-accent flex-1"
        />
      </div>
    </section>
    """
  end
end
