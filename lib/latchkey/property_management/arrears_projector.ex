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
  alias Latchkey.PropertyManagement.ArrearsFold
  alias Latchkey.PropertyManagement.Tenancy.Events, as: E

  def handle(%E.TenancyCommenced{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.RentFellDue{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.RentPaymentRecorded{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.TerminationNoticeGiven{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.KeysReturned{tenancy_id: tid}, _meta), do: project(tid)
  def handle(%E.TenancySettled{tenancy_id: tid}, _meta), do: project(tid)

  defp project(tenancy_id) do
    # Rebuild by folding the whole stream through the shared fold-and-derive
    # (spec D1) — the same code path the read-only inspector runs over a prefix, so
    # the two can never drift. The read model is disposable/rebuildable from the log.
    derived = fold_stream(tenancy_id)

    # Persist only the event-driven pointers. `days_behind` is derived on read
    # (Arrears.days_behind/2, ADR 0005 decision 6) — no frozen `as_of` here, so an
    # idle arrears tenant's counter climbs from the clock with no new event; the
    # `days_behind` the shared fold computes is unused on this write path.
    # `balance_cents` is the **live** fold — it keeps moving on post-terminal
    # payments. `final_balance_cents` is the **frozen** settlement snapshot captured
    # in the `TenancySettled` fold; refolding never re-derives it, so a later payment
    # updates the live balance without touching the snapshot.
    Arrears
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      status: derived.status,
      balance_cents: derived.balance_cents,
      oldest_unpaid_due_date: derived.oldest_unpaid_due_date,
      final_balance_cents: derived.final_balance_cents
    })
    |> Ash.create!()

    :ok
  end

  defp fold_stream(tenancy_id) do
    ("tenancy-" <> tenancy_id)
    |> EventStore.stream_forward()
    |> Enum.map(& &1.data)
    |> ArrearsFold.fold_and_derive()
  end
end
