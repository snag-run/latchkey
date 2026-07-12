defmodule Latchkey.Simulation.SeederIntegrationTest do
  @moduledoc """
  The seed scenario catalogue end to end (issue #44) through the real Commanded app +
  Postgres EventStore + ACL-1 + projector. Proves the acceptance criteria that a unit
  test can't: seeding replays the live engine + sweep through the Accounts → ACL-1 → PM
  seam, and post-seed the `Arrears` read model shows each tenancy at its **intended
  state as of today**.

  The event store is not sandboxed (Commanded runs its own DB connection), so the seed
  is run with a unique id prefix + accounts stream per test run; the `Arrears` read
  model IS sandboxed (shared mode). A fixed `today` keeps the backdated dates concrete.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.Simulation.Seeder

  require Ash.Query

  @today ~D[2026-06-15]

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    start_supervised!(Latchkey.PropertyManagement.PaymentAcl)

    prefix = "seed-it-#{System.unique_integer([:positive])}-"
    accounts_stream = "accounts-seed-it-#{System.unique_integer([:positive])}"

    results =
      Seeder.seed(
        today: @today,
        id_prefix: prefix,
        accounts_stream: accounts_stream
      )

    {:ok, results: results}
  end

  test "every seeded tenancy lands at its intended arrears/exit state as of today", %{
    results: results
  } do
    # All three scenarios seeded (none skipped — fresh streams per run).
    assert length(results) == 3
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

  defp arrears(tenancy_id) do
    Arrears |> Ash.Query.filter(tenancy_id == ^tenancy_id) |> Ash.read_one!()
  end

  defp tenancy_id_for(results, label) do
    Enum.find_value(results, fn
      %{scenario: %{label: ^label}, tenancy_id: tenancy_id} -> tenancy_id
      _other -> nil
    end)
  end
end
