defmodule Latchkey.Inspector.Broadcaster do
  @moduledoc """
  Read-only Commanded event handler that re-broadcasts every persisted event to
  `Phoenix.PubSub` for the dev inspector (spec `docs/spec/developer-view.md`,
  decision D5).

  Subscribes to **all** events, across all streams, and fans each one out to:

    - the global `dev:events` firehose topic (see `global_topic/0`) — every
      event, in commit order.
    - the event's own `dev:stream:<id>` topic (see `stream_topic/1`) — for a
      later ticket's stream-detail view to subscribe to.

  This is **one store subscription regardless of viewer count**, chosen over
  per-LiveView Commanded subscriptions (spec D5). It never appends, mutates, or
  dispatches a command — pure re-broadcast, no write-path involvement. If a
  future change makes this handler emit or write anything, it has stopped being
  this handler.
  """
  use Commanded.Event.Handler,
    application: Latchkey.CommandedApp,
    name: __MODULE__,
    consistency: :strong,
    start_from: :current

  @global_topic "dev:events"

  @doc "The global firehose topic every persisted event is broadcast to."
  @spec global_topic() :: String.t()
  def global_topic, do: @global_topic

  @doc "The per-stream topic a given `stream_id`'s events are broadcast to."
  @spec stream_topic(String.t()) :: String.t()
  def stream_topic(stream_id) when is_binary(stream_id), do: "dev:stream:#{stream_id}"

  @impl Commanded.Event.Handler
  def handle(event, %{stream_id: stream_id} = metadata) do
    message = {:dev_event, event, metadata}

    :ok = Phoenix.PubSub.broadcast(Latchkey.PubSub, @global_topic, message)
    :ok = Phoenix.PubSub.broadcast(Latchkey.PubSub, stream_topic(stream_id), message)

    :ok
  end
end
