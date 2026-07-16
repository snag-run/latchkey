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

  ## Idempotent on `{tenancy_id, event}`

  The enqueue is idempotent on `{tenancy_id, event}` via Oban uniqueness (`period:
  :infinity`, `states: :all`): a re-plan (a reset replan, a re-run) inserts **no
  duplicates**. Because each event kind is unique per tenancy in v1, `{tenancy_id,
  event}` uniquely identifies its single occurrence; the aggregate's own dedupe
  backstops it. *Extension point:* if a later change makes an event kind recur, the key
  must gain a stable per-occurrence world-line event id (spec).
  """
  use Oban.Worker, queue: :simulation, max_attempts: 3

  alias Latchkey.Clock
  alias Latchkey.Simulation.ScheduledEvent
  alias Latchkey.Simulation.Seeder
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario

  @time_zone "Australia/Sydney"

  # Idempotency: one job per {tenancy_id, event}, forever, across every job state — so a
  # re-plan never double-schedules regardless of whether the prior job is still
  # scheduled, already ran, or was cancelled.
  @unique [keys: [:tenancy_id, :event], period: :infinity, states: :all]

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

    scenarios
    |> Enum.flat_map(&changesets(&1, prefix, today))
    |> Enum.map(&Oban.insert!/1)
  end

  # The scheduled-job changesets for one scenario's future slice.
  defp changesets(%Scenario{} = scenario, prefix, today) do
    tenancy_id = prefix <> scenario.tenancy_id

    scenario
    |> Projection.future_timeline(tenancy_id, today)
    |> Enum.flat_map(fn {date, step} -> changeset(step, tenancy_id, date) end)
  end

  # `notice` and `vacate` are scheduled; a future payment (if any) is not — see moduledoc.
  defp changeset({:notice, notice}, tenancy_id, date) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "notice",
          given_on: Date.to_iso8601(notice.given_on),
          termination_date: Date.to_iso8601(notice.termination_date),
          as_of: Date.to_iso8601(notice.as_of)
        },
        date
      )
    ]
  end

  defp changeset({:exit, exit}, tenancy_id, date) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "vacate",
          keys_on: Date.to_iso8601(exit.keys_on)
        },
        date
      )
    ]
  end

  defp changeset({:payment, _payment}, _tenancy_id, _date), do: []

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
