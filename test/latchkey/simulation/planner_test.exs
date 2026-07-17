defmodule Latchkey.Simulation.PlannerTest do
  @moduledoc """
  The planner's enqueue seam (ADR 0011 / spec `docs/spec/simulation-engine.md`,
  "plan-once after seed"). No Commanded, no dispatch — the planner only *enqueues*
  scheduled `ScheduledEvent` jobs off the pure world-line, so these assert on the
  enqueued jobs (Oban manual testing), not on any side effect.
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Planner
  alias Latchkey.Simulation.ScheduledEvent
  alias Latchkey.Simulation.Seeder
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario
  alias Latchkey.Simulation.SeedGeneration

  @first_due ~D[2026-01-05]
  @rent 50_000

  # A deteriorating tenant who pays periods 0 and 1 on their due dates then misses
  # everything after (step_days so large the first post-grace period is instantly a
  # whole period behind). A hand-computable arrears trajectory — the same fixture the
  # WorldLine unit tests use — that a strict agent notices on 2026-02-02 (E/V 2026-02-16).
  defp exiting_scenario(overrides \\ []) do
    Enum.reduce(overrides, base_scenario(), fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  defp base_scenario do
    %Scenario{
      label: "strict-exit",
      tenancy_id: "t1",
      property_ref: "prop-t1",
      rent_amount_cents: @rent,
      first_due_date: @first_due,
      cycle: :weekly,
      profile: Profile.deteriorating(grace_periods: 2, step_days: 100, period_length_days: 7),
      schedule_count: 8,
      agent_archetype: :strict,
      overstay_days: 0
    }
  end

  # The Sydney calendar date a scheduled job fires on (its `scheduled_at`, read back in
  # the sim's wall-clock zone) — what "at the correct future date" means.
  defp fires_on(%Oban.Job{scheduled_at: at}) do
    at |> DateTime.shift_zone!("Australia/Sydney") |> DateTime.to_date()
  end

  defp job_for(event) do
    [worker: ScheduledEvent]
    |> all_enqueued()
    |> Enum.find(&(&1.args["event"] == event))
  end

  describe "plan/1 — enqueues the > today slice as scheduled jobs" do
    test "schedules the derived notice and vacate at their future dates" do
      # today sits after the paid periods but before the notice — both agent actions
      # are still ahead, so both are scheduled.
      jobs = Planner.plan(scenarios: [exiting_scenario()], today: ~D[2026-01-20])

      assert length(jobs) == 2

      assert_enqueued(worker: ScheduledEvent, args: %{tenancy_id: "t1", event: "notice"})
      assert_enqueued(worker: ScheduledEvent, args: %{tenancy_id: "t1", event: "vacate"})

      # Fired at the world-line's derived dates: notice 2026-02-02, vacate (E) 2026-02-16.
      assert fires_on(job_for("notice")) == ~D[2026-02-02]
      assert fires_on(job_for("vacate")) == ~D[2026-02-16]

      # Each carries its pre-decided payload for the next ticket's dumb dispatch.
      assert job_for("notice").args["termination_date"] == "2026-02-16"
      assert job_for("vacate").args["keys_on"] == "2026-02-16"

      # All on the dedicated :simulation queue.
      assert Enum.all?(all_enqueued(worker: ScheduledEvent), &(&1.queue == "simulation"))
    end

    test "past events are not enqueued — only the > today slice" do
      # today sits between the notice (2026-02-02) and the vacate (2026-02-16): the
      # notice is now backhistory (the seeder's slice), so only the vacate is scheduled.
      jobs = Planner.plan(scenarios: [exiting_scenario()], today: ~D[2026-02-10])

      assert length(jobs) == 1
      assert job_for("vacate")
      refute job_for("notice")
    end

    test "nothing is scheduled once the whole lifecycle is in the past" do
      Planner.plan(scenarios: [exiting_scenario()], today: ~D[2026-03-01])

      assert all_enqueued(worker: ScheduledEvent) == []
    end

    test "overstay shifts the scheduled vacate past E" do
      # overstay 9 → V = E + 9 = 2026-02-25; the notice still fires at 2026-02-02.
      Planner.plan(scenarios: [exiting_scenario(overstay_days: 9)], today: ~D[2026-01-20])

      assert fires_on(job_for("notice")) == ~D[2026-02-02]
      assert fires_on(job_for("vacate")) == ~D[2026-02-25]
    end
  end

  describe "plan/1 — only agent actions are scheduled" do
    test "a never-noticed tenant schedules nothing, and future payments are not enqueued" do
      # A reliable tenant with the whole payment schedule ahead of `today`: it never
      # crosses a threshold (no notice/vacate), and — proving payments are out of scope
      # for the planner — none of its future payment dates produce a job either.
      reliable =
        exiting_scenario(label: "reliable", tenancy_id: "t2", profile: Profile.reliable())

      Planner.plan(scenarios: [reliable], today: ~D[2026-01-01])

      assert all_enqueued(worker: ScheduledEvent) == []
    end
  end

  describe "plan/1 — idempotent on {tenancy_id, event}" do
    test "a second plan run inserts no duplicates" do
      opts = [scenarios: [exiting_scenario()], today: ~D[2026-01-20]]

      Planner.plan(opts)
      Planner.plan(opts)

      # Still exactly the one notice + one vacate — the re-plan collapsed onto them.
      assert length(all_enqueued(worker: ScheduledEvent)) == 2
      assert length(all_enqueued(worker: ScheduledEvent, args: %{event: "notice"})) == 1
      assert length(all_enqueued(worker: ScheduledEvent, args: %{event: "vacate"})) == 1
    end
  end

  describe "plan/1 — generation-aware uniqueness (issue #162)" do
    test "every planned job carries the current seed generation stamp" do
      Planner.plan(scenarios: [exiting_scenario()], today: ~D[2026-01-20])

      generations =
        all_enqueued(worker: ScheduledEvent) |> Enum.map(& &1.args["generation"])

      # Both jobs stamped with the live generation (0 — nothing has reset).
      assert generations == [0, 0]
    end

    test "a lingering old-generation job does not block a fresh, post-reset enqueue" do
      opts = [scenarios: [exiting_scenario()], today: ~D[2026-01-20]]

      # Plan the board at generation 0, then a reset advances the generation and replans.
      # The old jobs still sit in the queue (a claimed one is past deletion) — the fresh
      # enqueue must not collide with them on {tenancy_id, event}.
      Planner.plan(opts)
      assert SeedGeneration.advance() == 1
      Planner.plan(opts)

      notices = all_enqueued(worker: ScheduledEvent, args: %{event: "notice"})

      # Not collapsed onto the generation-0 job: the generation-1 notice enqueued alongside
      # it, one per generation — the race the atomic protocol closes.
      assert length(notices) == 2
      assert notices |> Enum.map(& &1.args["generation"]) |> Enum.sort() == [0, 1]
    end

    test "a re-plan under the same generation still inserts no duplicates" do
      opts = [scenarios: [exiting_scenario()], today: ~D[2026-01-20]]

      # No advance between runs → same generation → uniqueness still collapses the replan.
      Planner.plan(opts)
      Planner.plan(opts)

      assert length(all_enqueued(worker: ScheduledEvent, args: %{event: "notice"})) == 1
    end
  end

  describe "perform/1 — top-level job plans the catalogue" do
    test "plans the full catalogue as of the job's `today`, matching the world-line" do
      today = ~D[2026-07-16]

      # Independently derive how many future agent actions the catalogue implies, off the
      # same world-line the planner folds — the planner must enqueue exactly these.
      expected =
        today
        |> Seeder.catalogue()
        |> Enum.flat_map(&Projection.future_timeline(&1, &1.tenancy_id, today))
        |> Enum.count(fn {_date, {kind, _payload}} -> kind in [:notice, :exit] end)

      assert :ok = perform_job(Planner, %{"today" => Date.to_iso8601(today)})

      jobs = all_enqueued(worker: ScheduledEvent)
      assert length(jobs) == expected
      assert Enum.all?(jobs, &(&1.args["event"] in ["notice", "vacate"]))
    end
  end
end
