defmodule Latchkey.PropertyManagement.SweepIntegrationTest do
  @moduledoc """
  The sweep end to end (ADR 0005 decision 5) through the real Commanded app +
  EventStore + projector: a non-paying tenant surfaces in arrears after a sweep, and
  a double-run is idempotent and never emits a notice.

  Not sandbox-isolated for the event store (Commanded runs its own DB); the stream is
  keyed by a unique tenancy id per run. The Ash read model IS sandboxed (shared mode).
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.CommandedApp
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Sweep.TenancyWorker
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven

  require Ash.Query

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    :ok
  end

  defp commence!(tid) do
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
  end

  defp arrears(tid), do: Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()

  defp stream_events(tid) do
    ("tenancy-" <> tid) |> EventStore.stream_forward() |> Enum.map(& &1.data)
  end

  test "a non-paying tenant becomes visible in arrears after a sweep run" do
    tid = "sweep-#{System.unique_integer([:positive])}"
    commence!(tid)

    # Before the sweep the tenant is silent: no rent booked, so they look paid up.
    before = arrears(tid)
    assert before.oldest_unpaid_due_date == nil
    assert before.balance_cents == 0

    # The sweep books the owed RentFellDues through as_of — a child job per tenancy.
    assert :ok = perform_job(TenancyWorker, %{"tenancy_id" => tid, "as_of" => "2026-02-02"})

    # Now the arrears are visible: 5 weekly charges (01-05..02-02), none paid.
    after_sweep = arrears(tid)
    assert after_sweep.balance_cents == 250_000
    assert after_sweep.oldest_unpaid_due_date == ~D[2026-01-05]
    # days_behind is derived on read and rises purely with the clock.
    assert Arrears.days_behind(after_sweep, ~D[2026-02-02]) == 28
    assert Arrears.days_behind(after_sweep, ~D[2026-02-03]) == 29
  end

  test "double-run / retry is idempotent — no double charge, and no notice is ever emitted" do
    tid = "sweep-#{System.unique_integer([:positive])}"
    commence!(tid)

    args = %{"tenancy_id" => tid, "as_of" => "2026-02-02"}
    assert :ok = perform_job(TenancyWorker, args)
    assert :ok = perform_job(TenancyWorker, args)

    # The due_through pointer makes the second run a no-op: still 5 charges, not 10.
    events = stream_events(tid)
    assert Enum.count(events, &match?(%RentFellDue{}, &1)) == 5
    assert arrears(tid).balance_cents == 250_000

    # The sweep surfaces arrears; it never acts. No termination notice, ever.
    refute Enum.any?(events, &match?(%TerminationNoticeGiven{}, &1))
  end
end
