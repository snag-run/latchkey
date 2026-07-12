defmodule Latchkey.PropertyManagement.ArrearsProjector do
  @moduledoc """
  Projects the `Tenancy` stream into the `Arrears` read model (domain-model.md §7).
  A Commanded event handler that, per relevant event, refolds the tenancy's stream
  and upserts the Ash resource — Ash for read models only. `consistency: :strong`
  lets a dispatcher read the projection without racing. Rebuildable from the log.
  """
  use Commanded.Event.Handler,
    application: Latchkey.CommandedApp,
    name: __MODULE__,
    consistency: :strong,
    start_from: :origin

  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Aggregate
  alias Latchkey.PropertyManagement.Tenancy.Events, as: E

  def handle(%E.TenancyCommenced{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.RentFellDue{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.RentPaymentRecorded{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.TerminationNoticeGiven{tenancy_id: tid}, _meta), do: project(tid)

  defp project(tenancy_id) do
    core = fold_stream(tenancy_id)

    # Persist only the event-driven pointer. `days_behind` is derived on read
    # (Arrears.days_behind/2, ADR 0005 decision 6) — no frozen `as_of` here, so an
    # idle arrears tenant's counter climbs from the clock with no new event.
    Arrears
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      balance_cents: Tenancy.balance_cents(core),
      oldest_unpaid_due_date: Tenancy.oldest_unpaid_due_date(core)
    })
    |> Ash.create!()

    :ok
  end

  # Rebuild by folding the whole stream — the read model is disposable.
  defp fold_stream(tenancy_id) do
    ("tenancy-" <> tenancy_id)
    |> EventStore.stream_forward()
    |> Enum.reduce(%Aggregate{}, fn recorded, agg -> Aggregate.apply(agg, recorded.data) end)
    |> Map.fetch!(:core)
  end
end
