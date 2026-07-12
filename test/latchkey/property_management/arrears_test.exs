defmodule Latchkey.PropertyManagement.ArrearsTest do
  @moduledoc """
  Unit tests for the `days_behind` read-side computation (ADR 0005 decision 6):
  derived from `oldest_unpaid_due_date` and an as-of date, never stored.
  """
  use ExUnit.Case, async: true

  alias Latchkey.PropertyManagement.Arrears

  describe "days_behind/2" do
    test "is the calendar-day gap from the oldest unpaid due date to the as-of date" do
      record = %Arrears{oldest_unpaid_due_date: ~D[2026-01-05]}

      assert Arrears.days_behind(record, ~D[2026-01-05]) == 0
      assert Arrears.days_behind(record, ~D[2026-01-19]) == 14
      assert Arrears.days_behind(record, ~D[2026-02-02]) == 28
    end

    test "climbs day-to-day off the same idle record — no new event, only the clock moves" do
      record = %Arrears{oldest_unpaid_due_date: ~D[2026-01-05]}

      earlier = Arrears.days_behind(record, ~D[2026-02-02])
      later = Arrears.days_behind(record, ~D[2026-02-03])
      much_later = Arrears.days_behind(record, ~D[2026-03-04])

      assert later == earlier + 1
      assert much_later > later
    end

    test "is 0 when the tenant is paid up (no oldest unpaid due date)" do
      assert Arrears.days_behind(%Arrears{oldest_unpaid_due_date: nil}, ~D[2026-02-02]) == 0
    end

    test "clamps to 0 when the as-of date precedes the oldest unpaid due date" do
      record = %Arrears{oldest_unpaid_due_date: ~D[2026-01-05]}

      assert Arrears.days_behind(record, ~D[2026-01-01]) == 0
    end

    test "defaults the as-of date to the live Sydney clock" do
      record = %Arrears{oldest_unpaid_due_date: ~D[2020-01-01]}

      assert Arrears.days_behind(record) == Date.diff(Latchkey.Clock.today(), ~D[2020-01-01])
    end
  end
end
