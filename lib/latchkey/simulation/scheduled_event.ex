defmodule Latchkey.Simulation.ScheduledEvent do
  @moduledoc """
  The **thin scheduled-event worker** — the Oban job the planner enqueues for each
  future world-line agent action (ADR 0011 / spec `docs/spec/simulation-engine.md`,
  "plan-once after seed"). One job per derived action (`notice`, `vacate`), scheduled
  at the real-world date it occurs, on the dedicated `:simulation` queue.

  ## A dumb dispatch (issue #158)

  The planner decided *everything* at plan time; a fired job carries its pre-decided
  command in its `args` and does **no** arrears read and **no** run-time decision. When
  it fires it simply reconstitutes the command from those args and dispatches it through
  the live seam — `GiveTerminationNotice` for a `notice`, `ReturnKeys` for a `vacate` —
  with `consistency: :strong`, so on return the aggregate has folded it.

  Dispatching `ReturnKeys` at the derived vacate date is all the exit lifecycle needs:
  the aggregate itself catches accrual up to `E`, appends any overstay charge, and
  settles to `Terminal` (spec, "Exit lifecycle needs no new machinery"). The two
  commands drive the whole exit.

  ## `recorded_on` is left to default — this fires *live*

  Unlike the seeder, which backdates `recorded_on` to manufacture history, a fired job
  runs on the real-world date the event occurs, so it leaves `recorded_on` nil and lets
  the aggregate default it to `Clock.today/0` (ADR 0005). Because the job's scheduled
  instant *is* that day, the booking date and the pre-decided occurred date (`given_on`
  / `keys_on`) coincide — a live same-day booking.

  ## Idempotency lives on the enqueue

  Uniqueness (`{tenancy_id, event}`, no duplicate per plan-run) is enforced by the
  planner at insert time (`Latchkey.Simulation.Planner`), not here — a fired job is
  free to run once its scheduled instant arrives.

  ## Not yet: the reset-generation staleness guard

  The spec's generation stamp/guard (no-op a job planned under an older seed generation
  than the current one) is coupled to the reset-to-healthy cron (#92) that owns the
  generation lifecycle — no generation is stamped on jobs yet, so there is nothing to
  guard against. It lands with #92.
  """
  use Oban.Worker, queue: :simulation, max_attempts: 3

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Tenancy.Commands.GiveTerminationNotice
  alias Latchkey.PropertyManagement.Tenancy.Commands.ReturnKeys

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    args
    |> command()
    |> CommandedApp.dispatch(consistency: :strong)
  end

  # Reconstitute the pre-decided command from the job's args — dates parsed back from the
  # ISO strings the planner stamped in. No arrears read, no decision: the args *are* the
  # decision (issue #158).
  defp command(%{
         "event" => "notice",
         "tenancy_id" => tenancy_id,
         "given_on" => given_on,
         "termination_date" => termination_date,
         "as_of" => as_of
       }) do
    %GiveTerminationNotice{
      tenancy_id: tenancy_id,
      given_on: Date.from_iso8601!(given_on),
      termination_date: Date.from_iso8601!(termination_date),
      as_of: Date.from_iso8601!(as_of)
    }
  end

  defp command(%{"event" => "vacate", "tenancy_id" => tenancy_id, "keys_on" => keys_on}) do
    %ReturnKeys{tenancy_id: tenancy_id, keys_on: Date.from_iso8601!(keys_on)}
  end
end
