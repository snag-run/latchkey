defmodule Spike.Commanded.TenancyAggregateTest do
  @moduledoc """
  The Commanded aggregate is pure `execute`/`apply` — this whole test needs NO
  event store, NO app, NO database. That testability is the point (contrast the
  end-to-end demo in `mix spike.commanded.demo`).
  """
  use ExUnit.Case, async: true

  alias Spike.Commanded.Commands.{CommenceTenancy, GiveTerminationNotice, RecordPayment}
  alias Spike.Commanded.Events.TerminationNoticeGiven
  alias Spike.Commanded.TenancyAggregate, as: Agg

  defp apply_all(agg, events), do: Enum.reduce(List.wrap(events), agg, &Agg.apply(&2, &1))

  defp commenced_agg do
    agg = %Agg{}

    events =
      Agg.execute(agg, %CommenceTenancy{
        tenancy_id: "t1",
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-01-05]
      })

    apply_all(agg, events)
  end

  test "L7 gate refuses under 14 days behind" do
    assert {:error, {:not_in_arrears, 7}} =
             Agg.execute(commenced_agg(), %GiveTerminationNotice{
               tenancy_id: "t1",
               termination_date: ~D[2026-02-01],
               given_on: ~D[2026-01-12],
               as_of: ~D[2026-01-12]
             })
  end

  test "L7 gate accepts at/over 14 days behind, emitting catch-up then the notice" do
    events =
      Agg.execute(commenced_agg(), %GiveTerminationNotice{
        tenancy_id: "t1",
        termination_date: ~D[2026-02-14],
        given_on: ~D[2026-01-25],
        as_of: ~D[2026-01-25]
      })

    assert %TerminationNoticeGiven{grounds: :arrears} = List.last(events)
  end

  test "FIFO payment resets the clock (refused after clearing oldest week)" do
    agg = commenced_agg()

    pay =
      Agg.execute(agg, %RecordPayment{
        tenancy_id: "t1",
        amount_cents: 50_000,
        received_on: ~D[2026-01-25],
        source_payment_id: "p-1"
      })

    agg = apply_all(agg, pay)

    assert {:error, {:not_in_arrears, 13}} =
             Agg.execute(agg, %GiveTerminationNotice{
               tenancy_id: "t1",
               termination_date: ~D[2026-02-14],
               given_on: ~D[2026-01-25],
               as_of: ~D[2026-01-25]
             })
  end

  test "L2 refuses a second commence" do
    assert {:error, :already_commenced} =
             Agg.execute(commenced_agg(), %CommenceTenancy{
               tenancy_id: "t1",
               rent_amount_cents: 60_000,
               cycle: :weekly,
               first_due_date: ~D[2026-02-01]
             })
  end
end
