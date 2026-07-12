defmodule Latchkey.PropertyManagement.Sweep.CronWorker do
  @moduledoc """
  The daily sweep cron (ADR 0005 decision 5). Reads "now" **once** at the edge
  (`Clock.today/0`, the single wall-clock read-site) and fans out one `TenancyWorker`
  child job per live tenancy — favouring per-tenancy jobs for retry isolation and
  observability. This worker only *enqueues*; the child jobs dispatch the `CatchUp`
  commands. Every child is swept through the same `as_of`, so a single run is a
  consistent snapshot of the day.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Latchkey.Clock
  alias Latchkey.PropertyManagement.Sweep
  alias Latchkey.PropertyManagement.Sweep.TenancyWorker

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    as_of = Date.to_iso8601(Clock.today())

    Sweep.live_tenancy_ids()
    |> Enum.map(&TenancyWorker.new(%{tenancy_id: &1, as_of: as_of}))
    |> Oban.insert_all()

    :ok
  end
end
