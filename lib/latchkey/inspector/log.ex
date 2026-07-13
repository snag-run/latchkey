defmodule Latchkey.Inspector.Log do
  @moduledoc """
  Read-only **keyset pagination over the whole event store** — the entire `$all`
  stream, newest-first, across every stream (spec `docs/spec/developer-view.md`,
  decision D8, issue #114).

  This is the historical browser that complements — never replaces — the live
  firehose (D5). The firehose is a live tail capped at ~200 retained rows; this
  pages the full recorded history, oldest event to newest.

  ## Keyset, not offset

  Paging is keyed on the **global event number** (the `$all` stream's monotonic
  position), never a SQL `OFFSET`. A cursor is one integer boundary:

    * `nil` — the newest page (the head);
    * `{:before, n}` — the page of events strictly **older** than `n` (paging back
      through history);
    * `{:after, n}` — the page of events strictly **newer** than `n` (paging back
      toward the head).

  Each page carries the boundary event numbers to build the next/previous cursor,
  so navigation is O(page) and stable under concurrent appends (a new event at the
  head never shifts an older page's contents, unlike an offset).

  Strictly read-only: it reads the store and resolves display identity
  (`Latchkey.Inspector.Resolver`). It appends nothing and folds no state.
  """

  alias EventStore.RecordedEvent
  alias Latchkey.EventStore
  alias Latchkey.Inspector.Resolver

  @default_page_size 50

  @typedoc "A keyset cursor over the global event number."
  @type cursor :: nil | {:before, pos_integer()} | {:after, pos_integer()}

  @typedoc "One resolved, display-ready event row (newest-first within a page)."
  @type row :: %{
          id: pos_integer(),
          event_number: pos_integer(),
          stream_id: String.t(),
          position: non_neg_integer(),
          kind: :deep | :edge | :other,
          type: String.t(),
          occurred_on: Date.t() | nil,
          recorded_on: Date.t() | nil,
          divergent?: boolean(),
          identity: Resolver.identity(),
          created_at: DateTime.t()
        }

  @typedoc "A single page: rows plus the cursors to page newer/older, and the head."
  @type page :: %{
          rows: [row()],
          head: non_neg_integer(),
          page_size: pos_integer(),
          newer_cursor: pos_integer() | nil,
          older_cursor: pos_integer() | nil
        }

  @doc "The default page size (~50/page, D8)."
  @spec page_size() :: pos_integer()
  def page_size, do: @default_page_size

  @doc """
  Fetch one page of the global log, newest-first.

  `cursor` selects the page (see `t:cursor/0`); `opts` accepts `:page_size`.
  Returns a `t:page/0`; `newer_cursor`/`older_cursor` are `nil` at the head/floor
  respectively (nothing further in that direction).
  """
  @spec page(cursor(), keyword()) :: page()
  def page(cursor \\ nil, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    head = head_number()
    events = fetch(cursor, page_size)
    directory = Resolver.directory_map()
    holders = Resolver.payment_holders(events)
    rows = Enum.map(events, &to_row(&1, directory, holders))
    {newest, oldest} = bounds(events)

    %{
      rows: rows,
      head: head,
      page_size: page_size,
      # A page is at the head when its newest event is the store's head; it is at
      # the floor when its oldest event is the first ever recorded (number 1).
      newer_cursor: if(newest && newest < head, do: newest),
      older_cursor: if(oldest && oldest > 1, do: oldest)
    }
  end

  # ── Store reads ─────────────────────────────────────────────────────────────
  # For the `$all` stream, `start_version` is the global event number. Backward
  # reads return descending (newest-first); a forward read returns ascending, so we
  # reverse it to keep every page newest-first for display.
  defp fetch(nil, size), do: read_backward(-1, size)
  defp fetch({:before, n}, size), do: read_backward(n - 1, size)
  defp fetch({:after, n}, size), do: n |> read_forward(size) |> Enum.reverse()

  defp read_backward(start_version, size) do
    case EventStore.read_all_streams_backward(start_version, size) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  defp read_forward(after_number, size) do
    case EventStore.read_all_streams_forward(after_number + 1, size) do
      {:ok, events} -> events
      {:error, _reason} -> []
    end
  end

  # The head is the `$all` stream's version — the highest global event number.
  defp head_number do
    case EventStore.stream_info(:all) do
      {:ok, %{stream_version: version}} -> version
      _ -> 0
    end
  end

  defp bounds([]), do: {nil, nil}

  defp bounds(events) do
    numbers = Enum.map(events, & &1.event_number)
    {Enum.max(numbers), Enum.min(numbers)}
  end

  # ── Row building ────────────────────────────────────────────────────────────
  defp to_row(%RecordedEvent{} = event, directory, holders) do
    data = event.data
    occurred_on = Resolver.to_date(Map.get(data, :occurred_on))
    recorded_on = Resolver.to_date(Map.get(data, :recorded_on))

    %{
      id: event.event_number,
      event_number: event.event_number,
      stream_id: event.stream_uuid,
      position: event.stream_version,
      kind: stream_kind(event.stream_uuid),
      type: Resolver.short_type(data),
      occurred_on: occurred_on,
      recorded_on: recorded_on,
      divergent?: Resolver.divergent?(occurred_on, recorded_on),
      identity: resolve_identity(event.stream_uuid, data, directory, holders),
      created_at: event.created_at
    }
  end

  defp resolve_identity("accounts", data, directory, holders),
    do: Resolver.accounts_identity(data, directory, holders)

  defp resolve_identity("tenancy-" <> tenancy_id, _data, directory, _holders),
    do: Resolver.tenancy_identity(tenancy_id, directory)

  defp resolve_identity(stream_uuid, _data, _directory, _holders),
    do: Resolver.unknown_identity(stream_uuid)

  defp stream_kind("accounts"), do: :edge
  defp stream_kind("tenancy-" <> _rest), do: :deep
  defp stream_kind(_other), do: :other
end
