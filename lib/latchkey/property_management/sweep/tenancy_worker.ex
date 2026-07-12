defmodule Latchkey.PropertyManagement.Sweep.TenancyWorker do
  @moduledoc """
  Per-tenancy sweep child job (ADR 0005 decision 5): dispatches one `CatchUp` command,
  booking the `RentFellDue`s owed through `as_of` and advancing `due_through`.

  One job per tenancy for retry isolation and per-tenancy observability. Idempotent by
  the aggregate's `due_through` pointer — and safe under concurrency because Commanded
  serializes commands per aggregate instance, so an overlapping/retried sweep for the
  same tenancy sees the advanced pointer and emits nothing. Never issues notices.

  Dispatches with `consistency: :strong` so the job completes only once the `Arrears`
  read model reflects the catch-up — the sweep's job is *visibility*.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Sweep

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"tenancy_id" => tenancy_id, "as_of" => as_of}}) do
    command = Sweep.catch_up_command(tenancy_id, Date.from_iso8601!(as_of))
    CommandedApp.dispatch(command, consistency: :strong)
  end
end
