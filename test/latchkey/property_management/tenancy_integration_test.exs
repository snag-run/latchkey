defmodule Latchkey.PropertyManagement.TenancyIntegrationTest do
  @moduledoc """
  Full stack through the real Commanded app + Postgres EventStore + async projector.
  Proves the wiring the unit test can't: events persist, the L7 gate rules from the
  fold on the write side, and the Ash `Arrears` read model is projected.

  Not sandbox-isolated for the event store (Commanded runs its own DB); streams are
  keyed by a unique tenancy id per run. The Ash read model IS sandboxed (shared
  mode) so the projector and test share the connection and writes roll back.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C

  require Ash.Query

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    :ok
  end

  test "L7 gate rules from the fold, and arrears is projected" do
    tid = "it-#{System.unique_integer([:positive])}"

    assert :ok =
             CommandedApp.dispatch(
               %C.CommenceTenancy{
                 tenancy_id: tid,
                 rent_amount_cents: 50_000,
                 cycle: :weekly,
                 first_due_date: ~D[2026-01-05]
               },
               consistency: :strong
             )

    # 7 days behind (as_of on the 01-12 due date) → refused, no events appended
    assert {:error, {:not_in_arrears, 7}} =
             CommandedApp.dispatch(%C.GiveTerminationNotice{
               tenancy_id: tid,
               termination_date: ~D[2026-02-01],
               given_on: ~D[2026-01-12],
               as_of: ~D[2026-01-12]
             })

    # 28 days behind (as_of on the 02-02 due date) → accepted
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

    proj = Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()
    # 5 weekly charges booked (01-05..02-02), none paid
    assert proj.balance_cents == 250_000
    assert proj.days_behind == 28
    assert proj.oldest_unpaid_due_date == ~D[2026-01-05]
  end
end
