defmodule Latchkey.Simulation.ScheduledEventTest do
  @moduledoc """
  The thin scheduled-event worker's **dumb dispatch** (issue #158): a fired job carries
  its pre-decided command in `args` and, on firing, reconstitutes it and dispatches it
  through the live Commanded app — no arrears read, no run-time decision. These drive
  the real aggregate + Postgres EventStore + async projector (like the exit-settlement
  suite) to prove the right command fires on the derived date and the notice→vacate→
  settle path completes. Settlement arithmetic itself is the exit-settlement suite's job.
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy
  alias Latchkey.Simulation.ScheduledEvent

  require Ash.Query

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    :ok
  end

  defp commence(tid) do
    :ok =
      CommandedApp.dispatch(
        %CommenceTenancy{
          tenancy_id: tid,
          property_ref: "prop-" <> tid,
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05]
        },
        consistency: :strong
      )
  end

  defp projection(tid) do
    Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()
  end

  defp notice_args(tid) do
    %{
      "tenancy_id" => tid,
      "event" => "notice",
      "given_on" => "2026-02-02",
      "termination_date" => "2026-02-16",
      "as_of" => "2026-02-02"
    }
  end

  defp vacate_args(tid, keys_on \\ "2026-02-16") do
    %{"tenancy_id" => tid, "event" => "vacate", "keys_on" => keys_on}
  end

  test "a fired `notice` job dispatches GiveTerminationNotice with its derived dates" do
    tid = "sched-#{System.unique_integer([:positive])}"
    commence(tid)

    assert :ok = perform_job(ScheduledEvent, notice_args(tid))

    # The notice folded: the tenancy now has an effective end date (it is :ending), which
    # is exactly what makes the later ReturnKeys valid rather than :no_effective_end_date.
    proj = projection(tid)
    assert proj.status == :ending
  end

  test "the notice → vacate → settle path runs end-to-end through the aggregate" do
    tid = "sched-#{System.unique_integer([:positive])}"
    commence(tid)

    assert :ok = perform_job(ScheduledEvent, notice_args(tid))
    assert :ok = perform_job(ScheduledEvent, vacate_args(tid))

    # ReturnKeys at E drove catch-up-to-E and settlement inside the aggregate: six weeks
    # booked to E ($3,000), nothing paid → Terminal at that balance.
    proj = projection(tid)
    assert proj.status == :terminal
    assert proj.final_balance_cents == 300_000
  end

  test "a `vacate` job that overstays E fires ReturnKeys at the derived later date" do
    tid = "sched-#{System.unique_integer([:positive])}"
    commence(tid)

    assert :ok = perform_job(ScheduledEvent, notice_args(tid))
    # Keys returned a full week past E (02-16) → one $500 overstay week appended.
    assert :ok = perform_job(ScheduledEvent, vacate_args(tid, "2026-02-23"))

    proj = projection(tid)
    assert proj.status == :terminal
    assert proj.final_balance_cents == 350_000
  end
end
