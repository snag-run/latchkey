defmodule Latchkey.Simulation.WorldLineTest do
  @moduledoc """
  Pure unit tests for the world-line — no DB, no app, no clock. Given a tenant profile,
  a payment schedule, and an agent archetype, assert the derived notice/`E`/`V` dates,
  that determinism holds (same input → identical output), and that a tenant who never
  crosses the threshold is never noticed.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Schedule
  alias Latchkey.Simulation.WorldLine
  alias Latchkey.Simulation.WorldLine.Agent

  @holder "tenancy-t1"
  @first_due ~D[2026-01-05]
  @rent 50_000

  defp schedule(count), do: Schedule.weekly(@holder, @first_due, @rent, count)

  # A tenant who pays periods 0 and 1 on their due dates, then misses everything after:
  # `step_days` so large that the first post-grace period is instantly a whole period
  # behind and misses. A clean, hand-computable arrears trajectory.
  defp pays_two_then_stops do
    Profile.deteriorating(grace_periods: 2, step_days: 100, period_length_days: 7)
  end

  # Extract just the derived agent steps (notice/exit), dropping payments.
  defp agent_steps(events) do
    for {_date, {kind, payload}} <- events, kind in [:notice, :exit], do: {kind, payload}
  end

  describe "arrears trajectory → notice / E / V" do
    # Due dates (weekly from 2026-01-05): p2 falls due 2026-01-19 and is never paid, so
    # it is the oldest-unpaid from then on. days_behind crosses 14 on 2026-02-02.
    test "strict archetype notices the day days_behind crosses 14" do
      events = WorldLine.events(pays_two_then_stops(), schedule(8), Agent.strict())

      assert agent_steps(events) == [
               {:notice,
                %{
                  given_on: ~D[2026-02-02],
                  # E = notice + 14 (s88 statutory minimum)
                  termination_date: ~D[2026-02-16],
                  as_of: ~D[2026-02-02]
                }},
               # overstay 0 → compliant departer vacates at E
               {:exit, %{keys_on: ~D[2026-02-16]}}
             ]
    end

    test "lenient archetype notices later (30 days behind)" do
      events = WorldLine.events(pays_two_then_stops(), schedule(8), Agent.lenient())

      # oldest-unpaid due 2026-01-19; +30 = 2026-02-18; E = +14 = 2026-03-04
      assert agent_steps(events) == [
               {:notice,
                %{
                  given_on: ~D[2026-02-18],
                  termination_date: ~D[2026-03-04],
                  as_of: ~D[2026-02-18]
                }},
               {:exit, %{keys_on: ~D[2026-03-04]}}
             ]
    end

    test "overstay shifts V past E deterministically" do
      events = WorldLine.events(pays_two_then_stops(), schedule(8), Agent.strict(9))

      # E = 2026-02-16, V = E + 9 = 2026-02-25
      assert [_notice, {:exit, %{keys_on: ~D[2026-02-25]}}] = agent_steps(events)
    end

    test "crosses even when the arrears climb past the last scheduled due date" do
      # Only 4 periods (last due 2026-01-26); the strict crossing (2026-02-02) is after
      # the final due date, so the open-ended tail segment must still find it.
      events = WorldLine.events(pays_two_then_stops(), schedule(4), Agent.strict())

      assert [{:notice, %{given_on: ~D[2026-02-02]}}, {:exit, _}] = agent_steps(events)
    end
  end

  describe "no crossing → no agent events" do
    test "a reliable tenant is never noticed" do
      events = WorldLine.events(Profile.reliable(), schedule(8), Agent.strict())

      assert agent_steps(events) == []
    end

    test "a chronically-late-but-current tenant (under threshold) is never noticed" do
      # Always 10 days late — never reaches the strict 14-day gate.
      events = WorldLine.events(Profile.chronically_late(10), schedule(8), Agent.strict())

      assert agent_steps(events) == []
    end
  end

  describe "event list" do
    test "payments come through and are merged in date order with the agent events" do
      events = WorldLine.events(pays_two_then_stops(), schedule(8), Agent.strict())
      dates = Enum.map(events, fn {date, _step} -> date end)

      # Two payments (2026-01-05, 2026-01-12), then notice (2026-02-02), then exit
      # (2026-02-16) — sorted oldest-first.
      assert dates == Enum.sort(dates, Date)

      payment_dates =
        for {date, {:payment, _}} <- events, do: date

      assert payment_dates == [~D[2026-01-05], ~D[2026-01-12]]
    end

    test "the notice is ordered before its later exit" do
      events = WorldLine.events(pays_two_then_stops(), schedule(8), Agent.strict())

      kinds = Enum.map(events, fn {_date, {kind, _}} -> kind end)
      notice_idx = Enum.find_index(kinds, &(&1 == :notice))
      exit_idx = Enum.find_index(kinds, &(&1 == :exit))

      assert notice_idx < exit_idx
    end
  end

  describe "determinism" do
    test "same input → identical output, and a re-run reproduces the same schedule" do
      run = fn -> WorldLine.events(pays_two_then_stops(), schedule(8), Agent.lenient(3)) end

      assert run.() == run.()
    end
  end
end
