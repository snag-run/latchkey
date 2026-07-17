defmodule Latchkey.Simulation.ResetToHealthyIntegrationTest do
  @moduledoc """
  The **allowlist-scoped reset-to-healthy** end to end (issue #174, ADR 0007 decision 3),
  through the real `CommandedSupervisor` subtree + Postgres EventStore + `Arrears` projector.
  Proves the acceptance a unit test can't:

    1. Reset **wipes and reseeds** a healthy board — after `reset_to_healthy!/1` the seeded
       tenancies are folded back to their intended arrears/exit states (the streams were
       hard-deleted and the projector rebuilt from `:origin` over the reseed).
    2. Deletion is **allowlist-scoped**: the durable seed-generation counter is preserved
       (only advanced, never truncated) — users/auth have no table yet, so the counter is
       the durable-non-simulation-data canary — and the pure allowlist boundary
       (`simulation_stream?/2`) keeps only `tenancy-*` + the Accounts stream.
    3. Reset **advances the seed generation before** the purge/replan (issue #162).
    4. It is **idempotent under retry** — running it twice leaves a healthy board.

  The event store is not sandboxed (Commanded runs its own connection), so this is
  `async: false` and keyed to a unique id prefix + accounts stream; the `Arrears`/`Directory`
  read models and the seed-generation counter ARE sandboxed (shared mode). A fixed `today`
  keeps the backdated seed concrete.

  ## Seeding runs in a short-lived task

  The seeder opens **transient `EventStore.subscribe` subscriptions** in the process that
  runs it (to await each payment's ACL booking). Those subscriptions are linked and
  process-scoped, so if the seeding process is still alive when the reset later terminates
  the `CommandedApp`, the dying subscription would cascade a `:shutdown` back to it. In
  production that never happens — each reset runs in its own fresh Oban job process — so we
  reproduce that lifetime boundary here by running every seed **and** every reset in an
  `isolated/1` task that completes (and drops its subscriptions) before the next step.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedSupervisor
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.Simulation.Reset
  alias Latchkey.Simulation.Seeder
  alias Latchkey.Simulation.SeedGeneration

  require Ash.Query

  @today ~D[2026-06-15]

  # A small representative subset — one of each lifecycle shape — so the seam is proven
  # without reseeding the whole ~100-tenancy board.
  @sample_labels ~w(paid-up 20-days-behind-no-notice under-notice-01 exited-01)

  setup do
    start_supervised!(CommandedSupervisor)

    prefix = "reset-healthy-it-#{System.unique_integer([:positive])}-"
    accounts_stream = "accounts-reset-healthy-it-#{System.unique_integer([:positive])}"

    sample = @today |> Seeder.catalogue() |> Enum.filter(&(&1.label in @sample_labels))

    opts = [
      today: @today,
      id_prefix: prefix,
      accounts_stream: accounts_stream,
      scenarios: sample
    ]

    # Seed the initial board so the reset has something to wipe (isolated so its transient
    # subscriptions don't linger into the reset's subtree teardown — see moduledoc).
    results = isolated(fn -> Seeder.seed(opts) end)

    {:ok, opts: opts, results: results, sample: sample}
  end

  test "wipes and reseeds a healthy board (streams hard-deleted then rebuilt)", %{
    opts: opts,
    results: results,
    sample: sample
  } do
    # The board is healthy before the reset.
    for %{scenario: scenario, tenancy_id: tenancy_id} <- results do
      assert arrears(tenancy_id).status == scenario.expected.status
    end

    assert :ok = isolated(fn -> Reset.reset_to_healthy!(opts) end)

    # The board is healthy again — every sampled tenancy folded back to its intended state.
    assert length(results) == length(sample)

    for %{scenario: scenario, tenancy_id: tenancy_id} <- results do
      record = arrears(tenancy_id)
      expected = scenario.expected

      assert record.status == expected.status,
             "#{scenario.label}: #{inspect(record.status)} != #{inspect(expected.status)}"

      assert record.oldest_unpaid_due_date == expected.oldest_unpaid_due_date
      assert record.balance_cents == expected.balance_cents
    end
  end

  test "advances the seed generation before purge/replan, preserving the durable counter", %{
    opts: opts
  } do
    before = SeedGeneration.current()

    assert :ok = isolated(fn -> Reset.reset_to_healthy!(opts) end)

    # The counter survived the wipe (never truncated) and advanced by exactly one — the
    # generation-safe ordering (#162) and the durable-data-preservation proof in one.
    assert SeedGeneration.current() == before + 1
  end

  test "is idempotent under retry (twice leaves a healthy board)", %{
    opts: opts,
    results: results
  } do
    assert :ok = isolated(fn -> Reset.reset_to_healthy!(opts) end)
    assert :ok = isolated(fn -> Reset.reset_to_healthy!(opts) end)

    for %{scenario: scenario, tenancy_id: tenancy_id} <- results do
      assert arrears(tenancy_id).status == scenario.expected.status
    end
  end

  test "wipe is exactly allowlist-scoped at the store level (foreign stream survives)", %{
    opts: opts,
    results: results,
    sample: sample
  } do
    # A non-allowlisted stream written directly to the store (neither `tenancy-*` nor the
    # Accounts stream). It must survive the wipe untouched.
    keep = "keepme-#{System.unique_integer([:positive])}"
    :ok = Latchkey.EventStore.append_to_stream(keep, :any_version, [canary_event()])
    keep_before = event_ids(keep)
    assert length(keep_before) == 1

    # A representative allowlisted stream — one seeded tenancy — and its current event
    # instances, captured by their globally-unique event ids.
    tenancy_stream = "tenancy-" <> hd(results).tenancy_id
    tenancy_before = event_ids(tenancy_stream)
    assert tenancy_before != []

    assert :ok = isolated(fn -> Reset.reset_to_healthy!(opts) end)

    # The foreign stream is byte-for-byte intact: the allowlist never touched it.
    assert event_ids(keep) == keep_before

    # The allowlisted stream's pre-reset events were hard-deleted — the reseed created a
    # fresh set of event instances, so the old ids share nothing with the new ones.
    assert MapSet.disjoint?(MapSet.new(tenancy_before), MapSet.new(event_ids(tenancy_stream)))

    # `$all` is clean: the projector, rebuilt from :origin, folded ONLY the reseeded streams
    # (no ghost events from the wiped ones survive), so Arrears has exactly the reseeded
    # tenancies — and none from the foreign `keepme` stream.
    assert length(Ash.read!(Arrears)) == length(sample)
  end

  test "rejects a non-Accounts accounts_stream before any mutation" do
    before = SeedGeneration.current()

    assert_raise ArgumentError, fn ->
      Reset.reset_to_healthy!(accounts_stream: "users")
    end

    # It failed fast: the generation was not advanced, so nothing was wiped or reseeded.
    assert SeedGeneration.current() == before
  end

  test "the allowlist boundary keeps only tenancy-* and the Accounts stream" do
    assert Reset.simulation_stream?("tenancy-abc-01", "accounts")
    assert Reset.simulation_stream?("accounts", "accounts")
    assert Reset.simulation_stream?("accounts-seed-it-42", "accounts-seed-it-42")

    # Everything else is preserved — the primary safety boundary of the destructive reset.
    refute Reset.simulation_stream?("$all", "accounts")
    refute Reset.simulation_stream?("keepme-1", "accounts")
    refute Reset.simulation_stream?("users", "accounts")
    # A different Accounts stream name is out of scope — only the given one is allowlisted.
    refute Reset.simulation_stream?("accounts", "accounts-seed-it-42")
  end

  defp arrears(tenancy_id) do
    Arrears |> Ash.Query.filter(tenancy_id == ^tenancy_id) |> Ash.read_one!()
  end

  # The globally-unique event ids currently stored on a stream, in order.
  defp event_ids(stream_uuid) do
    stream_uuid |> Latchkey.EventStore.stream_forward() |> Enum.map(& &1.event_id)
  end

  # A minimal event on a non-simulation stream, used purely as a deletion-scope canary. Its
  # `event_type` maps to a real struct (`Date`) so it deserialises cleanly for the `$all`
  # handlers, none of which match it — Commanded's default `handle/2` no-ops it.
  defp canary_event do
    %EventStore.EventData{
      event_id: Ecto.UUID.generate(),
      event_type: "Elixir.Date",
      data: %{},
      metadata: %{}
    }
  end

  # Run `fun` in a short-lived task that completes before we return, so its transient
  # EventStore subscriptions are dropped with the process (mirroring a per-reset job
  # process). In shared-sandbox mode the task inherits DB access. Failures propagate.
  defp isolated(fun), do: fun |> Task.async() |> Task.await(:infinity)
end
