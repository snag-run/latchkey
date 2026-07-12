defmodule Latchkey.PropertyManagement.ArrearsFoldIntegrationTest do
  @moduledoc """
  The D1 parity guard (spec `docs/spec/developer-view.md`): folding the **full**
  persisted stream through the shared `ArrearsFold.fold_and_derive/1` yields exactly
  what the operational `ArrearsProjector` upserts to `pm_tenancy_arrears`. Both call
  the same code path, so this pins that they can never drift.

  Full stack through the real Commanded app + Postgres EventStore + async projector
  (mirrors `TenancyIntegrationTest`). The Ash read model is sandboxed (shared mode);
  the event store is keyed by a unique tenancy id per run.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedApp
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.ArrearsFold
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C

  require Ash.Query

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    :ok
  end

  test "fold(full stream) equals what the operational projector writes" do
    tid = "fold-parity-#{System.unique_integer([:positive])}"

    assert :ok =
             CommandedApp.dispatch(
               %C.CommenceTenancy{
                 tenancy_id: tid,
                 property_ref: "prop-" <> tid,
                 rent_amount_cents: 50_000,
                 cycle: :weekly,
                 first_due_date: ~D[2026-01-05]
               },
               consistency: :strong
             )

    # Drive arrears deep enough to clear the L7 gate, then a partial payment, so the
    # projected row exercises balance, oldest-unpaid and status together.
    assert :ok =
             CommandedApp.dispatch(
               %C.GiveTerminationNotice{
                 tenancy_id: tid,
                 termination_date: ~D[2026-03-01],
                 given_on: ~D[2026-02-02],
                 as_of: ~D[2026-02-02]
               },
               consistency: :strong
             )

    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 50_000,
                 received_on: ~D[2026-02-03],
                 source_payment_id: "pay-#{tid}"
               },
               consistency: :strong
             )

    proj = Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()

    derived =
      ("tenancy-" <> tid)
      |> EventStore.stream_forward()
      |> Enum.map(& &1.data)
      |> ArrearsFold.fold_and_derive()

    # The four fields the projector persists must match the shared fold exactly.
    assert derived.status == proj.status
    assert derived.balance_cents == proj.balance_cents
    assert derived.oldest_unpaid_due_date == proj.oldest_unpaid_due_date
    assert derived.final_balance_cents == proj.final_balance_cents
  end
end
