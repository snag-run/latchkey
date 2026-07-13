defmodule Latchkey.Simulation.SeederIntegrationTest do
  @moduledoc """
  The seed scenario catalogue end to end (issue #44 / ADR 0007) through the real
  Commanded app + Postgres EventStore + ACL-1 + projector. Proves the acceptance
  criteria that a unit test can't: seeding replays the live engine + sweep + agent
  commands through the Accounts → ACL-1 → PM seam, and post-seed the `Arrears` read
  model shows each tenancy at the **intended state as of today** derived by the pure
  projection — the guard that the projection can't drift from the live seam.

  It seeds a **representative subset** (not the whole ~100-tenancy board) covering
  every lifecycle status — active, arrears, under-notice, and exited/terminal — since
  the seam logic is identical across scenarios; the full catalogue is exercised purely
  and fast in `Latchkey.Simulation.SeederTest`.

  The event store is not sandboxed (Commanded runs its own DB connection), so the seed
  is run with a unique id prefix + accounts stream per test run; the `Arrears` read
  model IS sandboxed (shared mode). A fixed `today` keeps the backdated dates concrete.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.Simulation.Directory
  alias Latchkey.Simulation.Identity
  alias Latchkey.Simulation.Seeder

  require Ash.Query

  @today ~D[2026-06-15]

  # One scenario of each shape — the featured three (active / arrears / ending) plus a
  # generated healthy, arrears, under-notice and exited/terminal — so the seam is proven
  # against every lifecycle status without seeding all ~100.
  @sample_labels ~w(
    paid-up 20-days-behind-no-notice notice-issued-then-tenant-paid
    healthy-01 arrears-01 under-notice-01 exited-01
  )

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    start_supervised!(Latchkey.PropertyManagement.PaymentAcl)

    prefix = "seed-it-#{System.unique_integer([:positive])}-"
    accounts_stream = "accounts-seed-it-#{System.unique_integer([:positive])}"

    sample = @today |> Seeder.catalogue() |> Enum.filter(&(&1.label in @sample_labels))

    seed_opts = [
      today: @today,
      id_prefix: prefix,
      accounts_stream: accounts_stream,
      scenarios: sample
    ]

    results = Seeder.seed(seed_opts)

    {:ok, results: results, seed_opts: seed_opts, sample: sample}
  end

  test "every seeded tenancy lands at its intended arrears/exit state as of today", %{
    results: results,
    seed_opts: seed_opts,
    sample: sample
  } do
    # Every sampled scenario seeded (none skipped — fresh streams per run).
    assert length(results) == length(sample)
    assert Enum.all?(results, &(&1.status == :seeded))

    for %{scenario: scenario, tenancy_id: tenancy_id} <- results do
      record = arrears(tenancy_id)
      expected = scenario.expected

      assert record.status == expected.status,
             "#{scenario.label}: status #{inspect(record.status)} != #{inspect(expected.status)}"

      assert record.oldest_unpaid_due_date == expected.oldest_unpaid_due_date,
             "#{scenario.label}: oldest_unpaid #{inspect(record.oldest_unpaid_due_date)} " <>
               "!= #{inspect(expected.oldest_unpaid_due_date)}"

      assert record.balance_cents == expected.balance_cents,
             "#{scenario.label}: balance #{record.balance_cents} != #{expected.balance_cents}"

      assert Arrears.days_behind(record, @today) == expected.days_behind,
             "#{scenario.label}: days_behind #{Arrears.days_behind(record, @today)} " <>
               "!= #{expected.days_behind}"
    end

    # Coarse-idempotent reseed (documented fresh-store guard): a second seed with the
    # same options finds each tenancy already commenced, returns :skipped, and leaves
    # the Arrears records byte-identical — no double-charge, no drift.
    before = snapshot(results)
    reseed = Seeder.seed(seed_opts)

    assert Enum.all?(reseed, &(&1.status == :skipped))
    assert snapshot(reseed) == before
  end

  test "the paid-up tenant is square and looks paid up", %{results: results} do
    record = results |> tenancy_id_for("paid-up") |> arrears()

    assert record.status == :active
    assert record.oldest_unpaid_due_date == nil
    assert record.balance_cents == 0
    assert Arrears.days_behind(record, @today) == 0
  end

  test "the arrears tenant sits exactly 20 days behind with no notice", %{results: results} do
    record = results |> tenancy_id_for("20-days-behind-no-notice") |> arrears()

    assert record.status == :active
    assert record.oldest_unpaid_due_date == Date.add(@today, -20)
    assert Arrears.days_behind(record, @today) == 20
    # 14-day L7 gate is passed — eligible, but the button is unpulled (no notice).
    assert Arrears.days_behind(record, @today) >= 14
  end

  test "the void candidate is a paid-up, still-ending tenancy", %{results: results} do
    record = results |> tenancy_id_for("notice-issued-then-tenant-paid") |> arrears()

    # A notice was issued (status advanced to :ending) yet the tenant then paid off the
    # whole debt — square today, the notice standing over a now-current tenancy.
    assert record.status == :ending
    assert record.oldest_unpaid_due_date == nil
    assert record.balance_cents == 0
    assert Arrears.days_behind(record, @today) == 0
  end

  test "the exited tenant settles to a terminal state with a frozen final balance", %{
    results: results
  } do
    record = results |> tenancy_id_for("exited-01") |> arrears()

    # Keys were returned through the live ReturnKeys command, settling the tenancy.
    assert record.status == :terminal
    assert record.final_balance_cents != nil
  end

  test "the seeder upserts a Directory identity row per tenancy (off the event log)", %{
    results: results,
    seed_opts: seed_opts
  } do
    for %{scenario: scenario, tenancy_id: tenancy_id} <- results do
      row = directory(tenancy_id)

      # The Directory carries the deterministic display identity — name off tenancy_id,
      # address off property_ref — resolved by the same pure function the seeder uses.
      expected = Identity.resolve(tenancy_id, scenario.property_ref)
      assert row.tenant_name == expected.tenant_name
      assert row.property_address == expected.property_address
    end

    # A re-seed (every tenancy already commenced → :skipped) still upserts identity, so
    # the Directory is populated regardless of seed status.
    reseed = Seeder.seed(seed_opts)
    assert Enum.all?(reseed, &(&1.status == :skipped))

    for %{tenancy_id: tenancy_id} <- reseed do
      assert directory(tenancy_id) != nil
    end
  end

  test "interleaves the Accounts stream by arrival date across tenancies (issue #115)", %{
    seed_opts: seed_opts
  } do
    payments =
      seed_opts[:accounts_stream]
      |> EventStore.stream_forward()
      |> Enum.map(& &1.data)
      |> Enum.filter(&match?(%PaymentReceived{}, &1))

    # A meaningful board: several tenancies, many payments — enough to interleave.
    holders = Enum.map(payments, & &1.holder)
    assert length(Enum.uniq(holders)) > 1
    assert length(payments) > length(Enum.uniq(holders))

    # Chronological: `occurred_on` (arrival/value date) is non-decreasing down the stream.
    # Deserialized off the event store as ISO-8601 strings, which sort chronologically.
    dates = Enum.map(payments, & &1.occurred_on)
    assert dates == Enum.sort(dates)

    # Actually interleaved, not clustered-by-tenancy: a per-tenancy block layout has
    # exactly (#tenancies − 1) holder transitions; a date-ordered interleave has more.
    transitions =
      holders
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.count(fn [a, b] -> a != b end)

    assert transitions > length(Enum.uniq(holders)) - 1
  end

  test "reseed reproduces the same interleaving byte-for-byte (determinism, ADR 0005)", %{
    seed_opts: seed_opts
  } do
    # A fresh store keyed to a *new* accounts stream + id prefix, seeded from the same
    # scenarios: the interleaved order must be identical to the setup seed's.
    other_stream = "accounts-seed-it-#{System.unique_integer([:positive])}"
    other_prefix = "seed-it-#{System.unique_integer([:positive])}-"

    Seeder.seed(Keyword.merge(seed_opts, accounts_stream: other_stream, id_prefix: other_prefix))

    assert payment_shape(seed_opts[:accounts_stream], seed_opts[:id_prefix]) ==
             payment_shape(other_stream, other_prefix)
  end

  # The stream's payment order as prefix-independent tuples, so two runs on distinct
  # prefixes/streams compare equal iff they interleave the same tenancies in the same
  # order on the same dates.
  defp payment_shape(stream, prefix) do
    stream
    |> EventStore.stream_forward()
    |> Enum.map(& &1.data)
    |> Enum.filter(&match?(%PaymentReceived{}, &1))
    |> Enum.map(fn %PaymentReceived{holder: holder, occurred_on: on, amount_cents: cents} ->
      {String.replace_prefix(holder, "tenancy-" <> prefix, ""), on, cents}
    end)
  end

  defp arrears(tenancy_id) do
    Arrears |> Ash.Query.filter(tenancy_id == ^tenancy_id) |> Ash.read_one!()
  end

  defp directory(tenancy_id) do
    Directory |> Ash.Query.filter(tenancy_id == ^tenancy_id) |> Ash.read_one!()
  end

  # A comparable snapshot of every seeded tenancy's persisted read-model fields — used
  # to assert a reseed leaves the board unchanged.
  defp snapshot(results) do
    Map.new(results, fn %{tenancy_id: tenancy_id} ->
      record = arrears(tenancy_id)

      {tenancy_id,
       {record.status, record.oldest_unpaid_due_date, record.balance_cents,
        record.final_balance_cents}}
    end)
  end

  defp tenancy_id_for(results, label) do
    Enum.find_value(results, fn
      %{scenario: %{label: ^label}, tenancy_id: tenancy_id} -> tenancy_id
      _other -> nil
    end)
  end
end
