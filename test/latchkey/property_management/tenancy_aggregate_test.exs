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

  describe "exit settlement — boundary period pro-ration to E (issue #31)" do
    # A tenancy `:ending` with a **mid-week** effective end date E. Weekly $500 from
    # 01-05; nothing swept yet (due_through nil). E = 02-12 falls inside the period
    # [02-09, 02-16), 3 days in. Built directly so the maths is isolated from the L7
    # notice path.
    defp midweek_ending_state(e, opts \\ []) do
      %State{
        status: :ending,
        tenancy_id: "t1",
        rent_amount_cents: Keyword.get(opts, :rent_amount_cents, 50_000),
        cycle: :weekly,
        first_due_date: ~D[2026-01-05],
        due_through: Keyword.get(opts, :due_through),
        payments_total_cents: Keyword.get(opts, :payments_total_cents, 0),
        effective_end_date: e
      }
    end

    test "books full periods, then a single pro-rated boundary charge covering [start, E)" do
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-02-12]),
          %{keys_on: ~D[2026-02-12], recorded_on: ~D[2026-02-12]}
        )

      charges = Enum.filter(events, &(&1.type == :rent_fell_due))

      # Five whole weeks 01-05..02-02 (each [due, due+7)), then the boundary week.
      assert Enum.map(charges, & &1.occurred_on) ==
               [
                 ~D[2026-01-05],
                 ~D[2026-01-12],
                 ~D[2026-01-19],
                 ~D[2026-01-26],
                 ~D[2026-02-02],
                 ~D[2026-02-09]
               ]

      whole = Enum.take(charges, 5)
      boundary = List.last(charges)

      # Whole periods carry [due, due+7) and the full rent.
      assert Enum.all?(whole, &(&1.amount_cents == 50_000))
      assert Enum.all?(whole, &(Date.diff(&1.period_to, &1.period_from) == 7))

      # Boundary period: [02-09, E=02-12) = 3 days at $500/week → round_half_up(500×3/7).
      assert boundary.period_from == ~D[2026-02-09]
      assert boundary.period_to == ~D[2026-02-12]
      assert boundary.amount_cents == 21_429
    end

    test "a tenant leaving mid-week is charged only the days within the tenancy, never the whole week" do
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-02-12]),
          %{keys_on: ~D[2026-02-12], recorded_on: ~D[2026-02-12]}
        )

      boundary = events |> Enum.filter(&(&1.type == :rent_fell_due)) |> List.last()

      # 3 of 7 days → strictly less than a whole week's rent; E itself is not charged.
      assert boundary.amount_cents < 50_000
      assert Date.compare(boundary.period_to, ~D[2026-02-12]) == :eq
    end

    test "no RentFellDue fires on or after E (E belongs to the post-exit span)" do
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-02-12]),
          %{keys_on: ~D[2026-02-12], recorded_on: ~D[2026-02-12]}
        )

      for e when e.type == :rent_fell_due <- events do
        # The charge's due date (period_from) is before E; its span ends at E exclusive.
        assert Date.compare(e.period_from, ~D[2026-02-12]) == :lt
        assert Date.compare(e.period_to, ~D[2026-02-12]) != :gt
      end
    end

    test "final_balance_cents reflects the pro-rated boundary (5 whole weeks + partial)" do
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-02-12]),
          %{keys_on: ~D[2026-02-12], recorded_on: ~D[2026-02-12]}
        )

      settled = List.last(events)
      # 5 × 50_000 + 21_429 boundary − 0 paid.
      assert settled.type == :tenancy_settled
      assert settled.final_balance_cents == 271_429
    end

    test "a tenant who prepaid the whole final week ends with the correct refund owed" do
      # Prepay six whole weeks ($3,000) but only 5 whole + a 3-day boundary are charged.
      state = midweek_ending_state(~D[2026-02-12], payments_total_cents: 300_000)

      {:ok, events} =
        Tenancy.decide_return_keys(state, %{keys_on: ~D[2026-02-12], recorded_on: ~D[2026-02-12]})

      settled = List.last(events)
      # 271_429 charged − 300_000 paid = −28_571 → refund owed (signed negative).
      assert settled.final_balance_cents == -28_571
    end

    test "when E is a period boundary nothing is pro-rated (the #30 boundary-aligned case)" do
      # E = 02-16 = 01-05 + 7×6, an exact boundary. Whole periods run to E; the period
      # starting *on* E is post-exit and does not fire — no partial charge.
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-02-16]),
          %{keys_on: ~D[2026-02-16], recorded_on: ~D[2026-02-16]}
        )

      charges = Enum.filter(events, &(&1.type == :rent_fell_due))
      assert Enum.all?(charges, &(&1.amount_cents == 50_000))
      assert Enum.all?(charges, &(Date.diff(&1.period_to, &1.period_from) == 7))
      assert List.last(charges).occurred_on == ~D[2026-02-09]
    end

    test "pro-ration rounds half-up once on the final amount (per-day cents never rounded)" do
      # Weekly $100 (10_000c); boundary 1 day → 10_000 × 1 ÷ 7 = 1428.57 → 1429 (half-up),
      # not 7 × round(1428.57/…). E = 01-06, one day into the first period [01-05, 01-12).
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-01-06], rent_amount_cents: 10_000),
          %{keys_on: ~D[2026-01-06], recorded_on: ~D[2026-01-06]}
        )

      [boundary] = Enum.filter(events, &(&1.type == :rent_fell_due))
      assert boundary.period_from == ~D[2026-01-05]
      assert boundary.period_to == ~D[2026-01-06]
      assert boundary.amount_cents == 1_429
    end

    test "a month-boundary boundary period pro-rates on actual days spanned" do
      # first_due 01-05 → the period [01-26, 02-02) straddles month-end. E = 01-29 → the
      # boundary spans [01-26, 01-29) = 3 actual days (27th, 28th... i.e. Date.diff = 3).
      {:ok, events} =
        Tenancy.decide_return_keys(
          midweek_ending_state(~D[2026-01-29]),
          %{keys_on: ~D[2026-01-29], recorded_on: ~D[2026-01-29]}
        )

      boundary = events |> Enum.filter(&(&1.type == :rent_fell_due)) |> List.last()
      assert boundary.period_from == ~D[2026-01-26]
      assert boundary.period_to == ~D[2026-01-29]
      assert Date.diff(boundary.period_to, boundary.period_from) == 3
      assert boundary.amount_cents == 21_429
    end

    test "the pro-rated exit envelope round-trips through JSON rehydration" do
      agg = %Agg{core: midweek_ending_state(~D[2026-02-12])}

      # The shell adapts the pro-rated boundary charge to a `RentFellDue` struct carrying
      # `period_from`/`period_to`; rehydration coerces the JSON string dates back.
      folded =
        agg
        |> Agg.execute(%C.ReturnKeys{
          tenancy_id: "t1",
          keys_on: ~D[2026-02-12],
          recorded_on: ~D[2026-02-12]
        })
        |> Enum.map(&rehydrate/1)
        |> then(&apply_all(agg, &1))

      assert folded.core.status == :terminal
      assert folded.core.final_balance_cents == 271_429
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
