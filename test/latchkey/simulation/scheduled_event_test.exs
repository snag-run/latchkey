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

  alias Latchkey.Clock
  alias Latchkey.CommandedApp
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy
  alias Latchkey.PropertyManagement.Tenancy.Events.KeysReturned
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven
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

  # The first emitted event of the given struct type on the tenancy stream. Dates come
  # back as ISO strings — the raw persisted form the store round-trips (JSON) — so
  # callers assert against ISO strings.
  defp emitted(tid, struct) do
    ("tenancy-" <> tid)
    |> EventStore.stream_forward()
    |> Enum.map(& &1.data)
    |> Enum.find(&(&1.__struct__ == struct))
  end

  defp today_iso, do: Date.to_iso8601(Clock.today())

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

    # The pre-decided dates flow through: `occurred_on` is the planned served date, while
    # `recorded_on` is left to default to today — a live same-day booking, not a backdate
    # to `given_on` (contrast the seeder, which backdates to manufacture history).
    notice = emitted(tid, TerminationNoticeGiven)
    assert notice.occurred_on == "2026-02-02"
    assert notice.termination_date == "2026-02-16"
    assert notice.recorded_on == today_iso()
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

    # The keys-return carries the planned date as `occurred_on`, booked live (today).
    keys = emitted(tid, KeysReturned)
    assert keys.occurred_on == "2026-02-16"
    assert keys.recorded_on == today_iso()
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

    # The derived later vacate date is the one that fires as `occurred_on`.
    keys = emitted(tid, KeysReturned)
    assert keys.occurred_on == "2026-02-23"
  end
end
