defmodule Latchkey.PropertyManagement.Tenancy.AggregateTest do
  @moduledoc """
  Pure `execute`/`apply` of the Tenancy aggregate — no event store, no app, no DB.
  This testability is a headline reason we chose raw Commanded (ADR 0003).
  """
  use ExUnit.Case, async: true

  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Aggregate, as: Agg
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Tenancy.Events.KeysReturned
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancySettled
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven
  alias Latchkey.PropertyManagement.Tenancy.State

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

  # A tenancy in `:ending`: commenced (weekly $500 from 01-05), then a termination
  # notice served 02-02 (28 days behind → past the L7 gate) with the effective end
  # date E = 02-16 (a period boundary: 01-05 + 7×6). The notice's catch-up books the
  # five weeks 01-05..02-02.
  defp ending_agg do
    agg = commenced_agg()

    events =
      Agg.execute(agg, %C.GiveTerminationNotice{
        tenancy_id: "t1",
        termination_date: ~D[2026-02-16],
        given_on: ~D[2026-02-02],
        as_of: ~D[2026-02-02],
        recorded_on: ~D[2026-02-02]
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

  describe "exit settlement — KeysReturned → TenancySettled → Terminal (L9)" do
    test "returning keys on E closes the tenancy, booking whole periods up to E" do
      events =
        Agg.execute(ending_agg(), %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      # The notice swept 01-05..02-02; catch-up to E books only the 02-09 week.
      # The 02-16 period (starting *on* E) is post-exit and must NOT fire.
      charges = Enum.filter(events, &match?(%RentFellDue{}, &1))
      assert Enum.map(charges, & &1.occurred_on) == [~D[2026-02-09]]

      assert %KeysReturned{occurred_on: ~D[2026-02-16]} = Enum.at(events, -2)
      assert %TenancySettled{occurred_on: ~D[2026-02-16]} = List.last(events)
    end

    test "no step RentFellDue fires on or past E" do
      events =
        Agg.execute(ending_agg(), %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      for %RentFellDue{occurred_on: due} <- events do
        assert Date.compare(due, ~D[2026-02-16]) == :lt
      end
    end

    test "settlement transitions the tenancy to Terminal" do
      agg = ending_agg()

      events =
        Agg.execute(agg, %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      assert apply_all(agg, events).core.status == :terminal
    end

    test "a behind tenant settles with a positive final balance (debt) that persists" do
      # Six weeks booked by exit (01-05..02-09), nothing paid → +300_000 owed.
      [settled] =
        Agg.execute(ending_agg(), %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })
        |> Enum.filter(&match?(%TenancySettled{}, &1))

      assert settled.final_balance_cents == 300_000
    end

    test "a prepaid tenant settles with a negative final balance (refund owed)" do
      agg = ending_agg()

      # Prepay $3,500 before returning keys — more than the $3,000 that will be owed.
      pay =
        Agg.execute(agg, %C.RecordPayment{
          tenancy_id: "t1",
          amount_cents: 350_000,
          received_on: ~D[2026-02-10],
          source_payment_id: "p-prepaid",
          recorded_on: ~D[2026-02-10]
        })

      agg = apply_all(agg, pay)

      [settled] =
        Agg.execute(agg, %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })
        |> Enum.filter(&match?(%TenancySettled{}, &1))

      # 6 × $500 charged − $3,500 paid = −$500 → refund owed, signed negative.
      assert settled.final_balance_cents == -50_000
    end

    test "final_balance_cents equals the post-charge fold (snapshot of Σ charges − Σ payments)" do
      agg = ending_agg()

      events =
        Agg.execute(agg, %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      settled = List.last(events)
      folded = apply_all(agg, events)
      assert settled.final_balance_cents == Tenancy.balance_cents(folded.core)
    end

    test "L9 refuses keys-return on a live tenancy with no effective end date" do
      assert {:error, :no_effective_end_date} =
               Agg.execute(commenced_agg(), %C.ReturnKeys{
                 tenancy_id: "t1",
                 keys_on: ~D[2026-02-16],
                 recorded_on: ~D[2026-02-16]
               })
    end

    test "L9 refuses a second keys-return (Terminal stays final, L3)" do
      agg = ending_agg()

      first =
        Agg.execute(agg, %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      agg = apply_all(agg, first)

      assert {:error, :no_effective_end_date} =
               Agg.execute(agg, %C.ReturnKeys{
                 tenancy_id: "t1",
                 keys_on: ~D[2026-02-23],
                 recorded_on: ~D[2026-02-23]
               })
    end

    test "L9 refuses (no crash) an `:ending` state carrying no effective end date" do
      # A malformed/legacy fold: :ending with a nil E must not reach `Date.add(nil, -1)`.
      malformed = %State{status: :ending, effective_end_date: nil}

      assert {:error, :no_effective_end_date} =
               Tenancy.decide_return_keys(malformed, %{
                 keys_on: ~D[2026-02-16],
                 recorded_on: ~D[2026-02-16]
               })
    end

    test "L9 refuses keys returned before the effective end date E" do
      # ending_agg has E = 02-16; returning keys on 02-15 would terminalize early.
      assert {:error, :keys_returned_before_end_date} =
               Agg.execute(ending_agg(), %C.ReturnKeys{
                 tenancy_id: "t1",
                 keys_on: ~D[2026-02-15],
                 recorded_on: ~D[2026-02-15]
               })
    end

    test "a Terminal tenancy accrues no more rent on the catch-up sweep" do
      # Settle the tenancy, then sweep past E — no `RentFellDue` may be emitted (#41).
      agg = ending_agg()

      settled =
        Agg.execute(agg, %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      terminal = apply_all(agg, settled)
      assert terminal.core.status == :terminal

      assert [] =
               Agg.execute(terminal, %C.CatchUp{
                 tenancy_id: "t1",
                 as_of: ~D[2026-04-01],
                 recorded_on: ~D[2026-04-01]
               })
    end

    test "the exit envelope round-trips through JSON rehydration" do
      agg = ending_agg()

      events =
        Agg.execute(agg, %C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-16],
          recorded_on: ~D[2026-02-16]
        })

      folded =
        events
        |> Enum.map(&rehydrate/1)
        |> then(&apply_all(agg, &1))

      assert folded.core.status == :terminal
      assert folded.core.final_balance_cents == 300_000
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
