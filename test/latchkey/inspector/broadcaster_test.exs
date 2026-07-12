defmodule Latchkey.Inspector.BroadcasterTest do
  @moduledoc """
  The D5 fan-out seam (spec `docs/spec/developer-view.md`): every persisted event
  reaches both the global `dev:events` firehose topic and its own
  `dev:stream:<id>` topic. Full stack through the real `Commanded` app + Postgres
  `EventStore`, mirroring `ArrearsFoldIntegrationTest`'s setup.

  The handler declares `consistency: :strong`, so a `consistency: :strong`
  dispatch only returns once this handler has processed the event — no sleeps or
  polling needed to observe the broadcast.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedApp
  alias Latchkey.Inspector.Broadcaster
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Broadcaster)
    :ok
  end

  test "broadcasts a persisted event to the global topic and its per-stream topic" do
    tid = "firehose-#{System.unique_integer([:positive])}"
    stream_id = "tenancy-" <> tid

    # One relay process per topic, each tagging what it receives with which topic
    # delivered it. Same tuple on both topics would otherwise make two
    # `assert_receive`s pass even if the handler broadcast twice to `dev:events`
    # and never to `dev:stream:<id>`; the tags pin delivery to the *specific*
    # topic. `await_subscribed/1` gates the dispatch on both subscriptions being
    # live (sleep-free), so the strong-consistency broadcast can't race ahead.
    relay_topic(:global, Broadcaster.global_topic())
    relay_topic(:per_stream, Broadcaster.stream_topic(stream_id))
    await_subscribed([:global, :per_stream])

    assert :ok =
             CommandedApp.dispatch(
               %C.CommenceTenancy{
                 tenancy_id: tid,
                 property_ref: "prop-" <> tid,
                 rent_amount_cents: 50_000,
                 cycle: :weekly,
                 first_due_date: ~D[2026-01-05]
               },
               consistency: :strong
             )

    assert_receive {:relayed, :global,
                    {:dev_event, %TenancyCommenced{tenancy_id: ^tid}, %{stream_id: ^stream_id}}}

    assert_receive {:relayed, :per_stream,
                    {:dev_event, %TenancyCommenced{tenancy_id: ^tid}, %{stream_id: ^stream_id}}}
  end

  test "never dispatches a command or otherwise touches the write path" do
    refute function_exported?(Broadcaster, :dispatch, 1)
    refute function_exported?(Broadcaster, :dispatch, 2)
  end

  # Spawn a subscriber bound to exactly `topic` that forwards every message back
  # to the test process, tagged with `tag`, so each `assert_receive` proves
  # delivery on its own topic. Sends `{:subscribed, tag}` once the subscription
  # is live (see `await_subscribed/1`).
  defp relay_topic(tag, topic) do
    test_pid = self()

    spawn_link(fn ->
      :ok = Phoenix.PubSub.subscribe(Latchkey.PubSub, topic)
      send(test_pid, {:subscribed, tag})
      relay_loop(tag, test_pid)
    end)
  end

  defp relay_loop(tag, test_pid) do
    receive do
      message -> send(test_pid, {:relayed, tag, message})
    end

    relay_loop(tag, test_pid)
  end

  defp await_subscribed(tags) do
    for tag <- tags, do: assert_receive({:subscribed, ^tag})
  end
end
