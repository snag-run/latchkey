defmodule Latchkey.PropertyManagement.Tenancy.AggregateTest do
  @moduledoc """
  Pure `execute`/`apply` of the Tenancy aggregate — no event store, no app, no DB.
  This testability is a headline reason we chose raw Commanded (ADR 0003).
  """
  use ExUnit.Case, async: true

  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Aggregate, as: Agg
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven

  defp apply_all(agg, events), do: Enum.reduce(List.wrap(events), agg, &Agg.apply(&2, &1))

  defp commenced_agg do
    agg = %Agg{}

    events =
      Agg.execute(agg, %C.CommenceTenancy{
        tenancy_id: "t1",
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-01-05],
        recorded_on: ~D[2026-01-05]
      })

    apply_all(agg, events)
  end

  test "L7 gate refuses under 14 days behind" do
    assert {:error, {:not_in_arrears, 7}} =
             Agg.execute(commenced_agg(), %C.GiveTerminationNotice{
               tenancy_id: "t1",
               termination_date: ~D[2026-02-01],
               given_on: ~D[2026-01-12],
               as_of: ~D[2026-01-12]
             })
  end

  test "L7 gate accepts at/over 14 days behind, emitting catch-up then the notice" do
    events =
      Agg.execute(commenced_agg(), %C.GiveTerminationNotice{
        tenancy_id: "t1",
        termination_date: ~D[2026-02-14],
        given_on: ~D[2026-01-25],
        as_of: ~D[2026-01-25]
      })

    assert %TerminationNoticeGiven{grounds: :arrears} = List.last(events)
  end

  test "FIFO payment resets the clock (refused after clearing the oldest week)" do
    agg = commenced_agg()

    pay =
      Agg.execute(agg, %C.RecordPayment{
        tenancy_id: "t1",
        amount_cents: 50_000,
        received_on: ~D[2026-01-25],
        source_payment_id: "p-1"
      })

    agg = apply_all(agg, pay)

    assert {:error, {:not_in_arrears, 13}} =
             Agg.execute(agg, %C.GiveTerminationNotice{
               tenancy_id: "t1",
               termination_date: ~D[2026-02-14],
               given_on: ~D[2026-01-25],
               as_of: ~D[2026-01-25]
             })
  end

  test "refuses an unsupported (non-weekly) cycle" do
    assert {:error, :unsupported_cycle} =
             Agg.execute(%Agg{}, %C.CommenceTenancy{
               tenancy_id: "t1",
               rent_amount_cents: 250_000,
               cycle: :monthly,
               first_due_date: ~D[2026-01-05]
             })
  end

  test "L2 refuses a second commence" do
    assert {:error, :already_commenced} =
             Agg.execute(commenced_agg(), %C.CommenceTenancy{
               tenancy_id: "t1",
               rent_amount_cents: 60_000,
               cycle: :weekly,
               first_due_date: ~D[2026-02-01]
             })
  end

  describe "bitemporal envelope {occurred_on, recorded_on}" do
    test "commence stamps occurred_on = first due date and the provided recorded_on" do
      [event] =
        Agg.execute(%Agg{}, %C.CommenceTenancy{
          tenancy_id: "t1",
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05],
          recorded_on: ~D[2026-01-06]
        })

      assert %TenancyCommenced{occurred_on: ~D[2026-01-05], recorded_on: ~D[2026-01-06]} = event
      assert event.first_due_date == ~D[2026-01-05]
    end

    test "payment stamps occurred_on = received date" do
      events =
        Agg.execute(commenced_agg(), %C.RecordPayment{
          tenancy_id: "t1",
          amount_cents: 50_000,
          received_on: ~D[2026-01-05],
          source_payment_id: "p-1",
          recorded_on: ~D[2026-01-07]
        })

      assert %RentPaymentRecorded{occurred_on: ~D[2026-01-05], recorded_on: ~D[2026-01-07]} =
               List.last(events)
    end

    test "notice stamps occurred_on = served (given) date; termination_date stays payload" do
      events =
        Agg.execute(commenced_agg(), %C.GiveTerminationNotice{
          tenancy_id: "t1",
          termination_date: ~D[2026-03-01],
          given_on: ~D[2026-01-25],
          as_of: ~D[2026-01-25],
          recorded_on: ~D[2026-01-25]
        })

      notice = List.last(events)
      assert %TerminationNoticeGiven{occurred_on: ~D[2026-01-25]} = notice
      # kick-in date is payload, NOT the envelope date
      assert notice.termination_date == ~D[2026-03-01]
      assert notice.occurred_on != notice.termination_date
    end

    test "a catch-up RentFellDue has recorded_on >= occurred_on (lazy accrual, not backdating)" do
      # Booked on 03-01 but sweeping charges that fell due back in January.
      events =
        Agg.execute(commenced_agg(), %C.CatchUp{
          tenancy_id: "t1",
          as_of: ~D[2026-02-02],
          recorded_on: ~D[2026-03-01]
        })

      ticks = Enum.filter(events, &match?(%RentFellDue{}, &1))
      assert length(ticks) == 5

      for %RentFellDue{occurred_on: occurred, recorded_on: recorded} <- ticks do
        assert recorded == ~D[2026-03-01]
        assert Date.compare(recorded, occurred) in [:gt, :eq]
      end

      # ticks occurred on the historical weekly due dates, well before booking
      assert Enum.map(ticks, & &1.occurred_on) == [
               ~D[2026-01-05],
               ~D[2026-01-12],
               ~D[2026-01-19],
               ~D[2026-01-26],
               ~D[2026-02-02]
             ]
    end

    test "recorded_on defaults to Clock.today() when the command omits it" do
      [event] =
        Agg.execute(%Agg{}, %C.CommenceTenancy{
          tenancy_id: "t1",
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05]
        })

      assert event.recorded_on == Latchkey.Clock.today()
    end

    test "adapters round-trip the envelope through JSON rehydration" do
      events =
        Agg.execute(commenced_agg(), %C.CatchUp{
          tenancy_id: "t1",
          as_of: ~D[2026-01-19],
          recorded_on: ~D[2026-02-01]
        })

      # Fold the events after a JSON encode/decode cycle (what the EventStore
      # serializer does on replay: Dates come back as ISO strings).
      folded =
        events
        |> Enum.map(&rehydrate/1)
        |> then(&apply_all(commenced_agg(), &1))

      # occurred_on survived as a Date and drove the FIFO due-date reads
      assert Tenancy.oldest_unpaid_due_date(folded.core) == ~D[2026-01-05]
      assert folded.core.due_through == ~D[2026-01-19]
    end
  end

  # Simulate EventStore JSON rehydration: encode → decode → rebuild the struct
  # with string-valued dates, exactly as the serializer hands them to `apply/2`.
  defp rehydrate(%mod{} = event) do
    event
    |> Jason.encode!()
    |> Jason.decode!()
    |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> then(&struct(mod, &1))
  end
end
