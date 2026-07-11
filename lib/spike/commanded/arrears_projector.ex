defmodule Spike.Commanded.ArrearsProjector do
  @moduledoc """
  Read-model projector (§7): a Commanded event handler that folds the tenancy's
  stream and upserts the Ash `TenancyArrears` resource — Ash for read models only.
  `consistency: :strong` lets the demo dispatch and read the projection without a
  race. Rebuildable from the log, never the gate.
  """
  use Commanded.Event.Handler,
    application: Spike.Commanded.App,
    name: __MODULE__,
    consistency: :strong,
    start_from: :origin

  alias Spike.AshEvents.TenancyArrears
  alias Spike.Commanded.Events
  alias Spike.Commanded.{EventStore, TenancyAggregate}
  alias Spike.TenancyCore

  def handle(%Events.TenancyCommenced{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%Events.RentFellDue{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%Events.RentPaymentRecorded{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%Events.TerminationNoticeGiven{tenancy_id: tid}, _meta), do: project(tid)

  defp project(tenancy_id) do
    core = fold_stream(tenancy_id)
    as_of = core.due_through || core.first_due_date

    TenancyArrears
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      balance_cents: TenancyCore.balance_cents(core),
      days_behind: as_of && TenancyCore.days_behind(core, as_of),
      oldest_unpaid_due_date: TenancyCore.oldest_unpaid_due_date(core),
      as_of: as_of
    })
    |> Ash.create!()

    :ok
  end

  # Rebuild by folding the whole stream — proves the read model is disposable.
  defp fold_stream(tenancy_id) do
    ("tenancy-" <> tenancy_id)
    |> EventStore.stream_forward()
    |> Enum.reduce(%TenancyAggregate{}, fn recorded, agg ->
      TenancyAggregate.apply(agg, recorded.data)
    end)
    |> Map.fetch!(:core)
  end
end
