defmodule LatchkeyWeb.Inspector.LogPane do
  @moduledoc """
  The read-only **paginated event-log pane** (`LatchkeyWeb.InspectorLive`, spec
  `docs/spec/developer-view.md`, D8, issue #114): a historical browser over the
  entire event store — every event ever, across every stream — newest-first, with
  keyset paging back and forth through history.

  Distinct from the live firehose (D5, right rail): the firehose is a live tail;
  this is the full recorded history. Each row reuses the firehose row's shape
  (global event number · stream id · event type · timestamp) enriched with the
  event-log pane's bitemporal dates + divergence flag (D7) and the shared
  property-leading identity (`Latchkey.Inspector.Resolver`). Each row links through
  to its stream detail, scrubbed to that event's position where the stream folds.

  Presentational only: it renders pre-resolved rows (a LiveView stream, so it can't
  balloon memory) and paginates via `<.link patch>` — no store read, no fold, no
  mutation.
  """
  use LatchkeyWeb, :html

  import LatchkeyWeb.InspectorComponents, only: [caption: 1, read_more: 1]

  @doc """
  The paginated log. `rows` is the `@streams.log_rows` LiveView stream; `head` is
  the store's newest global event number; `range` is `{oldest, newest}` on the
  current page (or nil when empty); the cursors drive the pager links.
  """
  attr :rows, :any, required: true, doc: "the @streams.log_rows LiveView stream"
  attr :head, :integer, required: true, doc: "newest global event number in the store"
  attr :range, :any, default: nil, doc: "{oldest, newest} event number on this page, or nil"
  attr :newer_cursor, :integer, default: nil, doc: "event number to page toward the head, or nil"
  attr :older_cursor, :integer, default: nil, doc: "event number to page into history, or nil"
  attr :docs, :map, required: true, doc: "canonical doc URLs for read-more links"

  def log_pane(assigns) do
    ~H"""
    <section id="event-log-full" class="max-w-3xl">
      <header class="mb-3">
        <p class="text-[11px] font-semibold uppercase tracking-widest text-base-content/50">
          Event store · full history
        </p>
        <h2 class="mt-1 text-lg font-semibold">Global event log</h2>
      </header>

      <div class="mb-4 space-y-2">
        <.caption id="full-log-caption">
          Every event ever recorded, across <b>all streams</b>, newest first —
          the whole <b>$all</b>
          stream. This complements the live firehose on the right: the firehose is a live <i>tail</i>; this pages the full recorded history.
          <.read_more href={"#{@docs.domain_model}#3-events-producers"}>
            domain-model.md §3
          </.read_more>
        </.caption>

        <p id="full-log-immutability-note" class="text-xs leading-relaxed text-base-content/60">
          Read-only and <b class="text-base-content/80">append-only / immutable</b> — a historical
          browser, never an editor.
        </p>
      </div>

      <.pager
        id="log-pager-top"
        head={@head}
        range={@range}
        newer_cursor={@newer_cursor}
        older_cursor={@older_cursor}
      />

      <ol
        id="log-rows"
        phx-update="stream"
        class="mt-3 divide-y divide-base-300 border-y border-base-300"
      >
        <li
          id="log-empty"
          class="hidden only:block py-6 text-center text-xs text-base-content/50 italic"
        >
          No events recorded yet — the store is empty.
        </li>

        <li :for={{dom_id, row} <- @rows} id={dom_id} class="py-2.5">
          <.link
            navigate={row_path(row)}
            id={"log-row-#{row.event_number}"}
            class="block group -mx-2 px-2 py-1 rounded-md hover:bg-base-200 transition-colors"
          >
            <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <span class="font-mono text-[11px] text-base-content/40">#{row.event_number}</span>
              <span class="font-mono text-sm font-semibold group-hover:text-primary">
                {row.type}
              </span>
              <span class="font-mono text-[11px] text-base-content/55">{row.stream_id}</span>

              <span
                :if={row.divergent?}
                id={"log-divergence-#{row.event_number}"}
                class="badge badge-sm badge-warning gap-1"
                title="occurred_on and recorded_on differ (bitemporal divergence)"
              >
                occurred ≠ recorded
              </span>
            </div>

            <p
              id={"log-identity-#{row.event_number}"}
              class="mt-0.5 text-[11px] text-base-content/60"
            >
              <span class="font-medium text-base-content/80">{row.identity.property}</span>
              <span aria-hidden="true">·</span>
              <span>{row.identity.tenant}</span>
            </p>

            <p class="mt-0.5 flex flex-wrap gap-x-4 text-[11px] text-base-content/50">
              <span>occurred_on
              <span class="font-mono text-base-content/70">{fmt(row.occurred_on)}</span></span>
              <span>
                recorded_on
                <span class={[
                  "font-mono",
                  if(row.divergent?, do: "text-warning", else: "text-base-content/70")
                ]}>
                  {fmt(row.recorded_on)}
                </span>
              </span>
            </p>
          </.link>
        </li>
      </ol>

      <.pager
        id="log-pager-bottom"
        head={@head}
        range={@range}
        newer_cursor={@newer_cursor}
        older_cursor={@older_cursor}
      />
    </section>
    """
  end

  # ── Pager ───────────────────────────────────────────────────────────────────
  attr :id, :string, required: true
  attr :head, :integer, required: true
  attr :range, :any, default: nil
  attr :newer_cursor, :integer, default: nil
  attr :older_cursor, :integer, default: nil

  defp pager(assigns) do
    ~H"""
    <nav id={@id} aria-label="Event log pagination" class="flex items-center gap-2 text-xs">
      <.link
        :if={@newer_cursor}
        id={"#{@id}-newer"}
        patch={~p"/inspector/log?#{[after: @newer_cursor]}"}
        class="px-2.5 py-1 rounded-md border border-base-300 hover:bg-base-200 transition-colors"
      >
        ‹ Newer
      </.link>
      <span
        :if={is_nil(@newer_cursor)}
        id={"#{@id}-newer-disabled"}
        class="px-2.5 py-1 rounded-md border border-base-200 text-base-content/30"
      >
        ‹ Newer
      </span>

      <.link
        :if={@newer_cursor}
        id={"#{@id}-newest"}
        patch={~p"/inspector/log"}
        class="px-2.5 py-1 rounded-md border border-base-300 hover:bg-base-200 transition-colors"
      >
        Newest
      </.link>

      <span id={"#{@id}-range"} class="ml-auto font-mono text-[11px] text-base-content/50">
        <%= if @range do %>
          #{elem(@range, 0)}–#{elem(@range, 1)} of {@head}
        <% else %>
          0 of {@head}
        <% end %>
      </span>

      <.link
        :if={@older_cursor}
        id={"#{@id}-older"}
        patch={~p"/inspector/log?#{[before: @older_cursor]}"}
        class="ml-auto px-2.5 py-1 rounded-md border border-base-300 hover:bg-base-200 transition-colors"
      >
        Older ›
      </.link>
      <span
        :if={is_nil(@older_cursor)}
        id={"#{@id}-older-disabled"}
        class="ml-auto px-2.5 py-1 rounded-md border border-base-200 text-base-content/30"
      >
        Older ›
      </span>
    </nav>
    """
  end

  # A deep (tenancy) stream links scrubbed to this event's position (`?at=`); the
  # Accounts edge folds no state (no scrubber), so it links plainly; an unknown
  # stream isn't a navigable context, so it renders without a link target beyond
  # the stream-detail view (which honestly reports it unknown).
  defp row_path(%{kind: :deep, stream_id: stream_id, position: position}),
    do: ~p"/inspector/streams/#{stream_id}?#{[at: position]}"

  defp row_path(%{stream_id: stream_id}), do: ~p"/inspector/streams/#{stream_id}"

  defp fmt(%Date{} = date), do: Date.to_iso8601(date)
  defp fmt(nil), do: "—"
  defp fmt(other), do: to_string(other)
end
