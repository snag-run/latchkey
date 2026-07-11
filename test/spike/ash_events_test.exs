defmodule Spike.AshEventsTest do
  @moduledoc """
  Canonical bake-off demo (spike/README.md) against the pure-Ash spike.
  The L7 gate reads the FOLD, refusing then accepting as arrears cross 14 days.
  """
  use Latchkey.DataCase, async: true

  alias Spike.AshEvents.{Tenancy, TenancyArrears}

  require Ash.Query

  # weekly $500, first due 2026-01-05
  defp commence!(id) do
    assert {:ok, :appended} =
             Tenancy.commence(%{
               tenancy_id: id,
               rent_amount_cents: 50_000,
               cycle: :weekly,
               first_due_date: ~D[2026-01-05]
             })
  end

  test "L7 gate refuses under 14 days behind, accepts at/over" do
    id = "t-#{System.unique_integer([:positive])}"
    commence!(id)

    # 7 days behind (as_of 2026-01-12) → refused
    assert {:error, {:not_in_arrears, 7}} =
             Tenancy.give_termination_notice(%{
               tenancy_id: id,
               termination_date: ~D[2026-02-01],
               given_on: ~D[2026-01-12],
               as_of: ~D[2026-01-12]
             })

    # 20 days behind (as_of 2026-01-25), unpaid → accepted
    assert {:ok, :appended} =
             Tenancy.give_termination_notice(%{
               tenancy_id: id,
               termination_date: ~D[2026-02-14],
               given_on: ~D[2026-01-25],
               as_of: ~D[2026-01-25]
             })
  end

  test "FIFO payment resets the days_behind clock" do
    id = "t-#{System.unique_integer([:positive])}"
    commence!(id)

    # pay the oldest week on 2026-01-25 (books catch-up ticks, clears 2026-01-05)
    assert {:ok, :appended} =
             Tenancy.record_payment(%{
               tenancy_id: id,
               amount_cents: 50_000,
               received_on: ~D[2026-01-25],
               source_payment_id: "p-1"
             })

    # oldest unpaid is now 2026-01-12 → 13 days behind at 2026-01-25 → refused
    assert {:error, {:not_in_arrears, 13}} =
             Tenancy.give_termination_notice(%{
               tenancy_id: id,
               termination_date: ~D[2026-02-14],
               given_on: ~D[2026-01-25],
               as_of: ~D[2026-01-25]
             })
  end

  test "payment is idempotent on source_payment_id" do
    id = "t-#{System.unique_integer([:positive])}"
    commence!(id)

    p = %{
      tenancy_id: id,
      amount_cents: 50_000,
      received_on: ~D[2026-01-25],
      source_payment_id: "p-1"
    }

    assert {:ok, :appended} = Tenancy.record_payment(p)
    assert {:ok, :noop} = Tenancy.record_payment(p)
  end

  test "L2 refuses a second commence" do
    id = "t-#{System.unique_integer([:positive])}"
    commence!(id)

    assert {:error, :already_commenced} =
             Tenancy.commence(%{
               tenancy_id: id,
               rent_amount_cents: 60_000,
               cycle: :weekly,
               first_due_date: ~D[2026-02-01]
             })
  end

  test "read model is a disposable projection, not the gate" do
    id = "t-#{System.unique_integer([:positive])}"
    commence!(id)

    Tenancy.give_termination_notice(%{
      tenancy_id: id,
      termination_date: ~D[2026-02-14],
      given_on: ~D[2026-01-25],
      as_of: ~D[2026-01-25]
    })

    proj =
      TenancyArrears
      |> Ash.Query.filter(tenancy_id == ^id)
      |> Ash.read_one!()

    assert proj.days_behind == 20
    # unpaid: 3 weekly charges booked by 2026-01-25 (05, 12, 19) = $1500
    assert proj.balance_cents == 150_000
  end
end
