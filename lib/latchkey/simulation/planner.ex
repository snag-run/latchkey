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

  ## What gets scheduled: `payment`, `notice` and `vacate`

  Every future world-line step is scheduled — the tenant's future **payments** and the
  derived **agent actions** (the termination `notice` and the `vacate`/keys-return). A
  payment is the one *recurring* kind, so it cannot key on `{tenancy_id, event}` alone
  the way the once-per-lifecycle agent actions do; it uses the stable per-period
  `payment_id` as its idempotency `ref` instead (see the `@unique` note below). This is
  what keeps a reliable tenant paying as real time passes — the schedule is extended a
  runway past today (`Seeder.Catalogue`), and the planner realizes those future payments
  as scheduled jobs. Silent/terminal tenants simply have no future payment steps to
  schedule.

  ## Idempotent on `{tenancy_id, ref, generation}`

  The enqueue is idempotent on `{tenancy_id, ref, generation}` via Oban uniqueness
  (`period: :infinity`, `states: :all`): a re-plan under the **same** seed generation (a
  re-run) inserts **no duplicates**. `ref` is the per-occurrence world-line id — the
  once-per-lifecycle agent actions use their event name (`"notice"`/`"vacate"`), and the
  recurring payments use their stable per-period `payment_id` — so every occurrence keys
  uniquely *within a generation*; the aggregate's/ACL's own dedupe backstops it.

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

  # Idempotency: one job per {tenancy_id, ref, generation}, forever, across every job
  # state — so a re-plan under the same generation never double-schedules regardless of
  # whether the prior job is still scheduled, already ran, or was cancelled. `ref` is the
  # per-occurrence world-line id: `"notice"`/`"vacate"` (unique per tenancy) for the agent
  # actions, and the stable per-period `payment_id` for a payment — so recurring payments
  # each get their own key (the extension point noted above). `generation` keeps a lingering
  # old-generation job from blocking a post-reset replan (issue #162).
  @unique [keys: [:tenancy_id, :ref, :generation], period: :infinity, states: :all]

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
    accounts_stream = Keyword.get(opts, :accounts_stream, "accounts")

    # Read the live seed generation once and stamp every job planned this run with it, so
    # the whole plan is one atomic generation (issue #162). A reset advances the
    # generation *before* it calls the planner, so a replan stamps the new generation.
    generation = SeedGeneration.current()

    scenarios
    |> Enum.flat_map(&changesets(&1, prefix, today, generation, accounts_stream))
    |> Enum.map(&Oban.insert!/1)
  end

  # The scheduled-job changesets for one scenario's future slice.
  defp changesets(%Scenario{} = scenario, prefix, today, generation, accounts_stream) do
    tenancy_id = prefix <> scenario.tenancy_id

    scenario
    |> Projection.future_timeline(tenancy_id, today)
    |> Enum.flat_map(fn {date, step} ->
      changeset(step, tenancy_id, date, generation, accounts_stream)
    end)
  end

  # Each future world-line step becomes one scheduled job. `ref` is the per-occurrence
  # idempotency key (see `@unique`): the event name for the once-per-lifecycle agent
  # actions, the stable `payment_id` for a recurring payment.
  defp changeset({:notice, notice}, tenancy_id, date, generation, _accounts_stream) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "notice",
          ref: "notice",
          generation: generation,
          given_on: Date.to_iso8601(notice.given_on),
          termination_date: Date.to_iso8601(notice.termination_date),
          as_of: Date.to_iso8601(notice.as_of)
        },
        date
      )
    ]
  end

  defp changeset({:exit, exit}, tenancy_id, date, generation, _accounts_stream) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "vacate",
          ref: "vacate",
          generation: generation,
          keys_on: Date.to_iso8601(exit.keys_on)
        },
        date
      )
    ]
  end

  # A future payment fires *live* through the Accounts edge (not a Commanded command),
  # so the job carries the payment's edge inputs and the target Accounts stream. `ref`
  # is the stable per-period `payment_id`, so re-plans dedupe per payment.
  defp changeset({:payment, payment}, tenancy_id, date, generation, accounts_stream) do
    [
      new_job(
        %{
          tenancy_id: tenancy_id,
          event: "payment",
          ref: payment.payment_id,
          generation: generation,
          accounts_stream: accounts_stream,
          payment_id: payment.payment_id,
          amount_cents: payment.amount_cents,
          received_on: Date.to_iso8601(payment.occurred_on),
          holder: payment.holder
        },
        date
      )
    ]
  end

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
