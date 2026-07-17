defmodule Latchkey.Simulation.ResetIntegrationTest do
  @moduledoc """
  The Commanded **reset primitive** end to end (issue #173 / ADR 0007 decision 3),
  through the real `CommandedSupervisor` subtree — `CommandedApp` + Postgres EventStore +
  the `ArrearsProjector` — proving the acceptance the unit level can't:

    1. A cached aggregate survives a bare store wipe (the problem the issue names): after
       truncating the store *without* restarting the subtree, a reseed's `CommenceTenancy`
       still returns `:already_commenced` from the live aggregate's memory.
    2. `Reset.reset_event_store!/0` makes that same reseed **succeed** (`:ok`) and rebuilds
       a healthy `Arrears` board — the projector re-subscribed from origin and refolded.
    3. The primitive is **idempotent under retry** — running it twice leaves a cleanly
       reseedable store.

  The event store is not sandboxed (Commanded runs its own DB connection); these tests are
  `async: false`, so they never run alongside another integration test whose streams the
  whole-store wipe would clobber. The `Arrears` read model IS sandboxed (shared mode), so
  the projector — a separate process — sees it. A fixed `today` keeps the seed concrete.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedApp
  alias Latchkey.CommandedSupervisor
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.ArrearsProjector
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy
  alias Latchkey.Simulation.Reset

  require Ash.Query

  @today ~D[2026-06-15]

  setup do
    start_supervised!(CommandedSupervisor)
    :ok
  end

  test "a bare store wipe does NOT evict the cached aggregate; the reset primitive does" do
    tenancy_id = unique_id()

    assert :ok = commence(tenancy_id)

    # A second commence is rejected — the aggregate holds its committed state.
    assert {:error, :already_commenced} = commence(tenancy_id)

    # Naive reset: wipe the store out from under the live subtree WITHOUT restarting it.
    # The cached aggregate process never learns the stream is gone, so it still answers
    # `:already_commenced` from memory — exactly the failure #173 exists to fix.
    wipe_store_only!()
    assert {:error, :already_commenced} = commence(tenancy_id)

    # The primitive restarts the subtree, discarding the cached aggregate: the same
    # reseed now succeeds, and the projector — re-subscribed from origin — rebuilds a
    # healthy board for the re-commenced tenancy.
    assert :ok = Reset.reset_event_store!()
    assert :ok = commence(tenancy_id)

    record = arrears(tenancy_id)
    assert record.status == :active
    assert record.balance_cents == 0
    assert record.oldest_unpaid_due_date == nil
  end

  test "the reset primitive is idempotent under retry (twice leaves a reseedable store)" do
    tenancy_id = unique_id()

    assert :ok = commence(tenancy_id)

    # Two resets back to back — the second must not choke on the first's cold-started
    # subtree, and the store must stay cleanly reseedable.
    assert :ok = Reset.reset_event_store!()
    assert :ok = Reset.reset_event_store!()

    assert :ok = commence(tenancy_id)
    assert arrears(tenancy_id).status == :active
  end

  test "recovers a half-completed reset (a subtree child left terminated)" do
    tenancy_id = unique_id()

    assert :ok = commence(tenancy_id)

    # Simulate a reset that died partway: an out-of-band terminate leaves the
    # ArrearsProjector registered-but-`:undefined` in the supervisor — the interrupted
    # state. `ordered_child_ids/0` must still resolve every child's id from a tree with
    # some children already down, and the primitive must recover from it.
    :ok = Supervisor.terminate_child(CommandedSupervisor, child_id_for(ArrearsProjector))

    # Re-running the reset (the "re-run, not repair" contract) recovers to a cleanly
    # reseedable store: the reseed's CommenceTenancy succeeds and the board rebuilds.
    assert :ok = Reset.reset_event_store!()

    assert :ok = commence(tenancy_id)
    assert arrears(tenancy_id).status == :active
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  # The live supervisor child id whose callback module is `module`. Commanded's handler
  # ids are opaque `{module, opts}` tuples, so resolve from the running tree.
  defp child_id_for(module) do
    Enum.find_value(Supervisor.which_children(CommandedSupervisor), fn {id, _pid, _type, mods} ->
      if module in List.wrap(mods), do: id
    end)
  end

  # A healthy weekly tenancy commenced today. Returns `:ok` or `{:error, :already_commenced}`.
  defp commence(tenancy_id) do
    command = %CommenceTenancy{
      tenancy_id: tenancy_id,
      property_ref: "reset-it/1",
      rent_amount_cents: 50_000,
      cycle: :weekly,
      first_due_date: @today,
      recorded_on: @today
    }

    CommandedApp.dispatch_strong(command, [:already_commenced])
  end

  # Truncate events/streams/subscriptions/snapshots over a transient connection — the
  # store half of a reset, but WITHOUT the subtree restart, so the cached aggregate lives.
  # Mirrors `test/test_helper.exs`; used only to reproduce the naive-wipe failure.
  defp wipe_store_only! do
    config = EventStore.Config.parsed(Latchkey.EventStore, :latchkey)

    {:ok, conn} =
      config
      |> EventStore.Config.default_postgrex_opts()
      |> Postgrex.start_link()

    {:ok, _} = EventStore.Storage.Initializer.reset!(conn, config)
    true = Process.unlink(conn)
    true = Process.exit(conn, :shutdown)
    :ok
  end

  defp arrears(tenancy_id) do
    Arrears |> Ash.Query.filter(tenancy_id == ^tenancy_id) |> Ash.read_one!()
  end

  defp unique_id, do: "reset-it-#{System.unique_integer([:positive])}"
end
