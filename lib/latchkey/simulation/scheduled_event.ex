defmodule Latchkey.Simulation.ScheduledEvent do
  @moduledoc """
  The **thin scheduled-event worker** — the Oban job the planner enqueues for each
  future world-line agent action (ADR 0011 / spec `docs/spec/simulation-engine.md`,
  "plan-once after seed"). One job per derived action (`notice`, `vacate`), scheduled
  at the real-world date it occurs, on the dedicated `:simulation` queue.

  ## A dumb dispatch — stubbed here (issue #157)

  The planner decides *everything* at plan time; a fired job carries its pre-decided
  command in its `args` and does **no** arrears read. Turning a fired job into the
  dispatched command (`GiveTerminationNotice` for `notice`, `ReturnKeys` for `vacate`)
  — plus the seed-generation staleness guard (ADR 0011) — is the **next ticket**.
  Until then `perform/1` is a no-op stub: this ticket's contract is the *enqueued
  jobs*, asserted directly, not any dispatch side effect.

  ## Idempotency lives on the enqueue

  Uniqueness (`{tenancy_id, event}`, no duplicate per plan-run) is enforced by the
  planner at insert time (`Latchkey.Simulation.Planner`), not here — a fired job is
  free to run once its scheduled instant arrives.
  """
  use Oban.Worker, queue: :simulation, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
