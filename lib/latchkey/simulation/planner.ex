defmodule Latchkey.Simulation.Planner do
  @moduledoc """
  The **planner** — the top-level Oban job that, after `Latchkey.Simulation.Seeder.seed/1`,
  realizes each tenancy's *future* into scheduled Oban jobs (ADR 0011 / spec
  `docs/spec/simulation-engine.md`, "plan-once after seed").

  ## Plan-once, off the world-line

  The whole finite future is a deterministic function of the catalogue + dates, so it
  is fully known at seed time. The planner folds each scenario's world-line
  (`Latchkey.Simulation.WorldLine`, via `Seeder.Projection.future_timeline/3`), takes
  the `> today` slice, and enqueues each event as a scheduled `ScheduledEvent` job at
  its date. It is a **realizer, not a runtime decider**: it reads no live arrears and
  decides nothing at job-run time — there is no recurring decider cron.

  ## What gets scheduled: `notice` and `vacate`

  Only the derived **agent actions** are scheduled — the termination `notice` and the
  tenant's `vacate` (keys-return). Payments are *not* planned here: in v1 each
  scheduled event *kind* occurs **at most once per tenancy lifecycle** (no curing, no
  re-let), which is exactly what makes the `{tenancy_id, event}` idempotency key below
  sound — a property a recurring payment would break. (Reliable tenants keeping up
  future payments as real time passes is a separate concern the reset-to-healthy cron,
  issue #92, owns; the planner deliberately does not manufacture them.)

  ## Idempotent on `{tenancy_id, event, generation}`

  The enqueue is idempotent on `{tenancy_id, event, generation}` via Oban uniqueness
  (`period: :infinity`, `states: :all`): a re-plan under the **same** seed generation (a
  re-run) inserts **no duplicates**. Because each event kind is unique per tenancy in v1,
  `{tenancy_id, event}` uniquely identifies its single occurrence *within a generation*;
  the aggregate's own dedupe backstops it. *Extension point:* if a later change makes an
  event kind recur, the key must gain a stable per-occurrence world-line event id (spec).

  ## Generation-aware uniqueness (issue #162)

  The `generation` in the key is what makes the reset protocol atomic. Oban enforces
  uniqueness at **insert time** and matches **incomplete** jobs too (`states: :all`) — so
  a stale job Oban has already claimed (`executing`) under the *old* generation would,
  without generation in the key, collide with and **block** the fresh replan's enqueue,
  even though it is semantically a superseded occurrence. Reset advances the generation
  *before* replanning (`Latchkey.Simulation.SeedGeneration.advance/0`), so the new jobs
  carry a new generation and never collide with the lingering old-generation ones. The
  runtime dispatch's generation guard then no-ops that lingering claimed job.
  """
  use Oban.Worker, queue: :simulation, max_attempts: 3

  alias Latchkey.Clock
  alias Latchkey.Simulation.ScheduledEvent
  alias Latchkey.Simulation.Seeder
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario
  alias Latchkey.Simulation.SeedGeneration

  @time_zone "Australia/Sydney"

  # Idempotency: one job per {tenancy_id, event, generation}, forever, across every job
  # state — so a re-plan under the same generation never double-schedules regardless of
  # whether the prior job is still scheduled, already ran, or was cancelled. `generation`
  # keeps a lingering old-generation job from blocking a post-reset replan (issue #162).
  @unique [keys: [:tenancy_id, :event, :generation], period: :infinity, states: :all]

  @doc """
  Runs the planner as a top-level Oban job: plans the full catalogue as of `today`
  (from the job's `"today"` arg, else `Clock.today/0`) with the production id prefix.
  Enqueued after the seed (and, later, by the reset-to-healthy cron, #92).
  """
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    today =
      case args do
        %{"today" => iso} when is_binary(iso) -> Date.from_iso8601!(iso)
        _ -> Clock.today()
      end

    _jobs = plan(today: today)
    :ok
  end

  @doc """
  Fold every scenario's world-line and enqueue its `> today` agent actions as scheduled
  `ScheduledEvent` jobs — idempotent on `{tenancy_id, event}`. Returns the inserted (or
  pre-existing, on a duplicate) `Oban.Job`s.

  Mirrors `Seeder.seed/1`'s knobs so it plans exactly the board the seed produced:

    * `:today` — the reference date the world-line is cut at (defaults to `Clock.today/0`).
    * `:scenarios` — the scenarios to plan (defaults to the full `Seeder.catalogue/1`).
    * `:id_prefix` — prepended to each `tenancy_id`, matching the seeder's stream
      isolation (defaults to `""`).
  """
  @spec plan(keyword()) :: [Oban.Job.t()]
  def plan(opts \\ []) do
    today = Keyword.get(opts, :today, Clock.today())
    scenarios = Keyword.get_lazy(opts, :scenarios, fn -> Seeder.catalogue(today) end)
    prefix = Keyword.get(opts, :id_prefix, "")

    # Read the live seed generation once and stamp every job planned this run with it, so
    # the whole plan is one atomic generation (issue #162). A reset advances the
    # generation *before* it calls the planner, so a replan stamps the new generation.
    generation = SeedGeneration.current()

    scenarios
    |> Enum.flat_map(&changesets(&1, prefix, today, generation))
    |> Enum.map(&Oban.insert!/1)
  end

  # The scheduled-job changesets for one scenario's future slice.
  defp changesets(%Scenario{} = scenario, prefix, today, generation) do
    tenancy_id = prefix <> scenario.tenancy_id

    scenario
    |> Projection.future_timeline(tenancy_id, today)
    |> Enum.flat_map(fn {date, step} -> changeset(step, tenancy_id, date, generation) end)
  end

  # `notice` and `vacate` are scheduled; a future payment (if any) is not — see moduledoc.
  defp changeset({:notice, notice}, tenancy_id, date, generation) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "notice",
          generation: generation,
          given_on: Date.to_iso8601(notice.given_on),
          termination_date: Date.to_iso8601(notice.termination_date),
          as_of: Date.to_iso8601(notice.as_of)
        },
        date
      )
    ]
  end

  defp changeset({:exit, exit}, tenancy_id, date, generation) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "vacate",
          generation: generation,
          keys_on: Date.to_iso8601(exit.keys_on)
        },
        date
      )
    ]
  end

  defp changeset({:payment, _payment}, _tenancy_id, _date, _generation), do: []

  defp new_job(args, %Date{} = date) do
    ScheduledEvent.new(args, scheduled_at: scheduled_at(date), unique: @unique)
  end

  # Fire at the start of the event's day, Sydney wall-clock (ADR 0005), as a UTC instant
  # for Oban. Keeps the schedule aligned with the sim's day boundary.
  defp scheduled_at(%Date{} = date) do
    date
    |> DateTime.new!(~T[00:00:00], @time_zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end
end
