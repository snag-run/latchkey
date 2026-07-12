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
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue

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
    assert proj.oldest_unpaid_due_date == ~D[2026-01-05]

    # `days_behind` is derived on read (as-of the query date, Sydney) — NOT stored.
    # Oldest unpaid is 01-05, so as-of 02-02 the tenant is 28 days behind.
    assert Arrears.days_behind(proj, ~D[2026-02-02]) == 28

    # And it climbs day-to-day off the same idle projection — no new event, the
    # oldest-unpaid pointer never moved, only the clock advanced.
    assert Arrears.days_behind(proj, ~D[2026-02-03]) == 29
    assert Arrears.days_behind(proj, ~D[2026-03-04]) == 58

    # The bitemporal envelope survives the EventStore's JSON round-trip: each
    # swept RentFellDue carries {occurred_on, recorded_on}, and — booked live via
    # Clock.today() while charges fell due back in January — demonstrates lazy
    # accrual (recorded_on >= occurred_on), not backdating.
    ticks =
      ("tenancy-" <> tid)
      |> EventStore.stream_forward()
      |> Enum.map(& &1.data)
      |> Enum.filter(&match?(%RentFellDue{}, &1))

    assert length(ticks) == 5

    for %RentFellDue{occurred_on: occurred, recorded_on: recorded} <- ticks do
      assert Date.compare(to_date(recorded), to_date(occurred)) in [:gt, :eq]
    end
  end

  defp to_date(%Date{} = d), do: d
  defp to_date(s) when is_binary(s), do: Date.from_iso8601!(s)
end
