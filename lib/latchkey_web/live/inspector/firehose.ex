defmodule LatchkeyWeb.Inspector.Firehose do
  @moduledoc """
  The global live event **firehose** (`LatchkeyWeb.InspectorLive`, spec
  `docs/spec/developer-view.md`, D5): a right-rail feed that shows each event as
  it lands, following at head.

  Presentational only. `LatchkeyWeb.InspectorLive` owns the `dev:events`
  PubSub subscription (`Latchkey.Inspector.Broadcaster`) and the LiveView
  stream itself (`phx-update="stream"` — no memory ballooning); this module
  just renders the `@streams.firehose` collection it's handed.

  Row identity is deliberately thin in this slice: event type + stream id + a
  timestamp only. Naming each row by property/tenant needs a Directory
  read-model and `property_ref` that don't exist yet — that's a later slice,
  not this one.

  Each row is clickable and carries its `{stream_id, position}` via
  `phx-click`/`phx-value-*`, but the click only acknowledges structurally (see
  `LatchkeyWeb.InspectorLive.handle_event/3`) — navigating into a stream-detail
  view at that position is issue #86, once that view exists.
  """
  use LatchkeyWeb, :html

  attr :stream, :any, required: true, doc: "the LiveView firehose stream (@streams.firehose)"

  def firehose_feed(assigns) do
    ~H"""
    <aside id="firehose" aria-label="Live event firehose" class="flex flex-col h-full">
      <div class="flex items-baseline justify-between gap-2 px-3.5 py-3 border-b border-base-300">
        <span class="text-xs font-bold uppercase tracking-wide text-base-content/70">
          Firehose
        </span>
        <span class="font-mono text-[11px] text-base-content/50">dev:events</span>
      </div>

      <div
        id="firehose-feed"
        phx-update="stream"
        class="flex-1 overflow-y-auto divide-y divide-base-300"
      >
        <p
          id="firehose-empty"
          class="hidden only:block p-4 text-center text-xs text-base-content/50 max-w-[24ch] mx-auto"
        >
          No live events yet — events appear here as the simulation emits them.
        </p>
        <button
          :for={{id, row} <- @stream}
          id={id}
          type="button"
          phx-click="firehose_row_click"
          phx-value-stream_id={row.stream_id}
          phx-value-position={row.position}
          class="w-full text-left px-3.5 py-2 hover:bg-base-200 transition-colors"
        >
          <p class="font-mono text-xs font-semibold">{row.event_type}</p>
          <p class="text-[11px] text-base-content/60">{row.stream_id}</p>
          <p class="text-[10.5px] text-base-content/40">{row.timestamp}</p>
        </button>
      </div>
    </aside>
    """
  end
end
