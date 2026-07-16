defmodule Latchkey.Simulation.ScheduledEventTest do
  @moduledoc """
  The thin scheduled-event worker is a **no-op stub** in this ticket (#157): the
  planner's contract is the enqueued jobs, not dispatch. Turning a fired job into a
  command (`GiveTerminationNotice` / `ReturnKeys`) is the next ticket — until then a
  fired job must simply succeed.
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.Simulation.ScheduledEvent

  test "perform/1 is a no-op that succeeds (dispatch is the next ticket)" do
    assert :ok = perform_job(ScheduledEvent, %{"tenancy_id" => "t1", "event" => "vacate"})
  end
end
