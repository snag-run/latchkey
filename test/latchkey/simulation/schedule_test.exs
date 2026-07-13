defmodule Latchkey.Simulation.ScheduleTest do
  @moduledoc """
  Unit tests for the cadence-aware `Schedule` period builders (ADR 0009). Each builder
  must mirror the aggregate's accrual walk: weekly `+7`, fortnightly `+14`, and monthly
  from the commencement anchor (month-end clamp), so seeded payments line up with the
  `RentFellDue` charges the tenancy books.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Simulation.Schedule

  describe "weekly/4" do
    test "builds one 7-day period per week from the anchor" do
      schedule = Schedule.weekly("tenancy-a", ~D[2026-01-01], 50_000, 3)

      assert schedule.holder == "tenancy-a"

      assert Enum.map(schedule.periods, & &1.due_on) ==
               [~D[2026-01-01], ~D[2026-01-08], ~D[2026-01-15]]

      assert Enum.map(schedule.periods, & &1.index) == [0, 1, 2]
      assert Enum.all?(schedule.periods, &(&1.amount_cents == 50_000))
    end
  end

  describe "fortnightly/4" do
    test "builds one 14-day period per fortnight from the anchor" do
      schedule = Schedule.fortnightly("tenancy-b", ~D[2026-01-01], 60_000, 3)

      assert Enum.map(schedule.periods, & &1.due_on) ==
               [~D[2026-01-01], ~D[2026-01-15], ~D[2026-01-29]]

      assert Enum.all?(schedule.periods, &(&1.amount_cents == 60_000))
    end
  end

  describe "monthly/4" do
    test "advances one calendar month per period from the anchor" do
      schedule = Schedule.monthly("tenancy-c", ~D[2026-01-15], 200_000, 3)

      assert Enum.map(schedule.periods, & &1.due_on) ==
               [~D[2026-01-15], ~D[2026-02-15], ~D[2026-03-15]]
    end

    test "clamps a month-end anchor and lets the day-of-month come back (from-anchor)" do
      # Jan 31 anchor: Feb has no 31st so it clamps to Feb 28, but March DOES, so the
      # 31st "comes back" — the from-anchor rule (ADR 0009 decision 2), not stuck at 28.
      schedule = Schedule.monthly("tenancy-d", ~D[2026-01-31], 200_000, 5)

      assert Enum.map(schedule.periods, & &1.due_on) ==
               [~D[2026-01-31], ~D[2026-02-28], ~D[2026-03-31], ~D[2026-04-30], ~D[2026-05-31]]
    end
  end

  describe "for_cycle/5" do
    test "dispatches to the matching per-cadence builder" do
      anchor = ~D[2026-01-01]

      assert Schedule.for_cycle(:weekly, "h", anchor, 50_000, 2) ==
               Schedule.weekly("h", anchor, 50_000, 2)

      assert Schedule.for_cycle(:fortnightly, "h", anchor, 50_000, 2) ==
               Schedule.fortnightly("h", anchor, 50_000, 2)

      assert Schedule.for_cycle(:monthly, "h", anchor, 50_000, 2) ==
               Schedule.monthly("h", anchor, 50_000, 2)
    end
  end
end
