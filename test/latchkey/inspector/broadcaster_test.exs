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

    :ok = Phoenix.PubSub.subscribe(Latchkey.PubSub, Broadcaster.global_topic())
    :ok = Phoenix.PubSub.subscribe(Latchkey.PubSub, Broadcaster.stream_topic(stream_id))

    assert :ok =
             CommandedApp.dispatch(
               %C.CommenceTenancy{
                 tenancy_id: tid,
                 rent_amount_cents: 50_000,
                 cycle: :weekly,
                 first_due_date: ~D[2026-01-05]
               },
               consistency: :strong
             )

    assert_receive {:dev_event, %TenancyCommenced{tenancy_id: ^tid}, %{stream_id: ^stream_id}}
    assert_receive {:dev_event, %TenancyCommenced{tenancy_id: ^tid}, %{stream_id: ^stream_id}}
  end

  test "never dispatches a command or otherwise touches the write path" do
    refute function_exported?(Broadcaster, :dispatch, 1)
    refute function_exported?(Broadcaster, :dispatch, 2)
  end
end
