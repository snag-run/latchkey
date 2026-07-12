defmodule Latchkey.Simulation.BehaviourTest do
  @moduledoc """
  Seam-1 unit tests for the tenant behaviour engine — pure, no DB, no app. Given a
  profile and a schedule, assert the exact `PaymentReceived` sequence the archetype
  produces, that seeded jitter is reproducible, and that scripted overrides win.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Simulation.Behaviour
  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Schedule

  @holder "tenancy-t1"
  @first_due ~D[2026-01-05]
  @rent 50_000

  defp schedule(count), do: Schedule.weekly(@holder, @first_due, @rent, count)

  # A compact view of a payment sequence: {index-derived id, amount, received date}.
  defp shape(payments) do
    Enum.map(payments, fn %PaymentReceived{} = p ->
      {p.payment_id, p.amount_cents, p.occurred_on}
    end)
  end

  describe "reliable" do
    test "pays the full amount on every due date" do
      payments = Behaviour.payments(Profile.reliable(), schedule(3))

      assert shape(payments) == [
               {"tenancy-t1-pmt-0", 50_000, ~D[2026-01-05]},
               {"tenancy-t1-pmt-1", 50_000, ~D[2026-01-12]},
               {"tenancy-t1-pmt-2", 50_000, ~D[2026-01-19]}
             ]
    end

    test "each payment is a live fact: recorded_on equals the received date" do
      [first | _] = Behaviour.payments(Profile.reliable(), schedule(1))
      assert first.occurred_on == first.recorded_on
      assert first.holder == @holder
    end
  end

  describe "chronically_late(+n)" do
    test "pays the full amount every period, n days after the due date" do
      payments = Behaviour.payments(Profile.chronically_late(3), schedule(3))

      assert shape(payments) == [
               {"tenancy-t1-pmt-0", 50_000, ~D[2026-01-08]},
               {"tenancy-t1-pmt-1", 50_000, ~D[2026-01-15]},
               {"tenancy-t1-pmt-2", 50_000, ~D[2026-01-22]}
             ]
    end

    test "late_by 0 is equivalent to reliable" do
      assert Behaviour.payments(Profile.chronically_late(0), schedule(3)) ==
               Behaviour.payments(Profile.reliable(), schedule(3))
    end
  end

  describe "deteriorating" do
    test "on time through grace, then slips later each period, then misses once a whole period behind" do
      # defaults: grace 2, step 2, period 7 → i0/i1 on time; i2 +2; i3 +4; i4 +6;
      # i5 would be +8 >= 7 → miss; i6 miss.
      payments = Behaviour.payments(Profile.deteriorating(), schedule(7))

      assert shape(payments) == [
               {"tenancy-t1-pmt-0", 50_000, ~D[2026-01-05]},
               {"tenancy-t1-pmt-1", 50_000, ~D[2026-01-12]},
               {"tenancy-t1-pmt-2", 50_000, Date.add(~D[2026-01-19], 2)},
               {"tenancy-t1-pmt-3", 50_000, Date.add(~D[2026-01-26], 4)},
               {"tenancy-t1-pmt-4", 50_000, Date.add(~D[2026-02-02], 6)}
             ]

      # Periods 5 and 6 are missed entirely.
      assert length(payments) == 5
    end

    test "grace/step are tunable" do
      payments =
        Behaviour.payments(Profile.deteriorating(grace_periods: 0, step_days: 3), schedule(4))

      offsets =
        Enum.map(payments, fn p ->
          Date.diff(p.occurred_on, Date.add(@first_due, p_index(p) * 7))
        end)

      # i0 slipped 1 → +3; i1 slipped 2 → +6; i2 slipped 3 → +9 >= 7 miss; i3 miss.
      assert offsets == [3, 6]
    end
  end

  describe "sporadic (seeded jitter)" do
    test "same seed produces the same lateness sequence (reproducible)" do
      profile = Profile.sporadic(seed: 42)
      run1 = Behaviour.payments(profile, schedule(12))
      run2 = Behaviour.payments(profile, schedule(12))

      assert shape(run1) == shape(run2)
      # Determinism must not collapse to "always pay" or "never pay".
      assert run1 != []
      assert length(run1) < 12
    end

    test "a different seed produces a different sequence" do
      a = Behaviour.payments(Profile.sporadic(seed: 1), schedule(12))
      b = Behaviour.payments(Profile.sporadic(seed: 2), schedule(12))
      refute shape(a) == shape(b)
    end

    test "seeding a subset reproduces the same per-period result as the full run" do
      profile = Profile.sporadic(seed: 7)
      full = Behaviour.payments(profile, schedule(12))

      # A schedule that starts later still yields the same decision for shared indices,
      # because each period's draw is keyed on its own index, not iteration state.
      subset = Behaviour.payments(profile, Schedule.weekly(@holder, @first_due, @rent, 5))
      shared = Enum.filter(full, fn p -> p_index(p) < 5 end)
      assert shape(subset) == shape(shared)
    end

    test "lateness stays within max_late_days" do
      payments = Behaviour.payments(Profile.sporadic(seed: 99, max_late_days: 5), schedule(20))

      for p <- payments do
        offset = Date.diff(p.occurred_on, Date.add(@first_due, p_index(p) * 7))
        assert offset >= 0 and offset <= 5
      end
    end
  end

  describe "scripted overrides" do
    test "miss-then-double-pay: period 0 missed, period 1 pays double on its due date" do
      profile =
        Profile.reliable()
        |> Profile.with_override(0, :miss)
        |> Profile.with_override(1, {:pay, amount_cents: 2 * @rent})

      payments = Behaviour.payments(profile, schedule(3))

      assert shape(payments) == [
               {"tenancy-t1-pmt-1", 100_000, ~D[2026-01-12]},
               {"tenancy-t1-pmt-2", 50_000, ~D[2026-01-19]}
             ]
    end

    test "an override can also force lateness via :offset" do
      profile = Profile.with_override(Profile.reliable(), 0, {:pay, offset: 4})
      [first | _] = Behaviour.payments(profile, schedule(1))
      assert first.occurred_on == Date.add(@first_due, 4)
    end

    test "an override wins over the archetype rule for its period only" do
      profile = Profile.with_override(Profile.chronically_late(3), 1, :miss)
      payments = Behaviour.payments(profile, schedule(3))

      # period 1 missed; 0 and 2 still pay 3 days late per the archetype.
      assert shape(payments) == [
               {"tenancy-t1-pmt-0", 50_000, ~D[2026-01-08]},
               {"tenancy-t1-pmt-2", 50_000, ~D[2026-01-22]}
             ]
    end
  end

  describe "decide/3 (the live per-day payments)" do
    test "returns the single payment received that day, as a list" do
      profile = Profile.reliable()

      assert [%PaymentReceived{payment_id: "tenancy-t1-pmt-1"}] =
               Behaviour.decide(profile, schedule(3), ~D[2026-01-12])
    end

    test "returns [] on a day with no payment" do
      assert Behaviour.decide(Profile.reliable(), schedule(3), ~D[2026-01-13]) == []
    end

    test "returns [] on a missed period's due date" do
      profile = Profile.with_override(Profile.reliable(), 0, :miss)
      assert Behaviour.decide(profile, schedule(3), @first_due) == []
    end

    test "returns every payment when a late override collides with a later due date" do
      # Period 0 paid 7 days late lands on period 1's own due date — both are due that
      # day. Returning a single payment would silently drop one; decide/3 must not.
      profile = Profile.with_override(Profile.reliable(), 0, {:pay, offset: 7})
      collision_date = Date.add(@first_due, 7)

      assert [
               %PaymentReceived{payment_id: "tenancy-t1-pmt-0"},
               %PaymentReceived{payment_id: "tenancy-t1-pmt-1"}
             ] = Behaviour.decide(profile, schedule(3), collision_date)
    end

    test "iterating decide/3 over every date reproduces payments/2 exactly" do
      # A schedule with a same-day collision, so the reconciliation is non-trivial.
      profile = Profile.with_override(Profile.reliable(), 0, {:pay, offset: 7})
      sched = schedule(3)
      full = Behaviour.payments(profile, sched)

      dates = full |> Enum.map(& &1.occurred_on) |> Enum.uniq()
      reconstructed = Enum.flat_map(dates, &Behaviour.decide(profile, sched, &1))

      assert shape(reconstructed) == shape(full)
    end
  end

  describe "archetype option validation" do
    test "deteriorating rejects a negative step_days (would pay before the due date)" do
      assert_raise ArgumentError, fn -> Profile.deteriorating(step_days: -1) end
    end

    test "deteriorating rejects a non-positive period_length_days" do
      assert_raise ArgumentError, fn -> Profile.deteriorating(period_length_days: 0) end
    end

    test "deteriorating rejects a negative grace_periods" do
      assert_raise ArgumentError, fn -> Profile.deteriorating(grace_periods: -1) end
    end

    test "sporadic rejects a pay_probability above 1.0 (would always pay)" do
      assert_raise ArgumentError, fn -> Profile.sporadic(pay_probability: 2.0) end
    end

    test "sporadic rejects a negative pay_probability" do
      assert_raise ArgumentError, fn -> Profile.sporadic(pay_probability: -0.1) end
    end

    test "sporadic rejects a negative max_late_days" do
      assert_raise ArgumentError, fn -> Profile.sporadic(max_late_days: -1) end
    end
  end

  describe "override validation" do
    test "rejects a non-positive amount_cents (Accounts rejects it downstream)" do
      assert_raise ArgumentError, fn ->
        Profile.with_override(Profile.reliable(), 0, {:pay, amount_cents: 0})
      end
    end

    test "rejects a negative offset (payment before its due date)" do
      assert_raise ArgumentError, fn ->
        Profile.with_override(Profile.reliable(), 1, {:pay, offset: -1})
      end
    end
  end

  # Recover a payment's period index from its deterministic id ("...-pmt-<index>").
  defp p_index(%PaymentReceived{payment_id: id}) do
    id |> String.split("-pmt-") |> List.last() |> String.to_integer()
  end
end
