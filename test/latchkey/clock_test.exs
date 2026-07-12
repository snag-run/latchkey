defmodule Latchkey.ClockTest do
  use ExUnit.Case, async: true

  alias Latchkey.Clock

  describe "today/1" do
    test "resolves an instant to its Australia/Sydney calendar date" do
      # 2026-07-11 23:30 UTC is already 2026-07-12 in Sydney (UTC+10, no DST).
      instant = ~U[2026-07-11 23:30:00Z]

      assert Clock.today(instant) == ~D[2026-07-12]
    end

    test "the UTC/Sydney boundary: a different calendar day in UTC resolves to the Sydney date" do
      # UTC calendar day is the 11th; Sydney (UTC+10) has already ticked to the 12th.
      instant = ~U[2026-07-11 23:30:00Z]

      assert instant.day == 11
      assert Clock.today(instant).day == 12
    end

    test "is DST-aware: during Sydney daylight saving the offset is UTC+11" do
      # January is AEDT (UTC+11). 2026-01-15 13:30 UTC -> 2026-01-16 00:30 Sydney.
      instant = ~U[2026-01-15 13:30:00Z]

      assert Clock.today(instant) == ~D[2026-01-16]
    end
  end

  describe "today/0" do
    test "returns a Date in the Australia/Sydney zone" do
      assert %Date{} = Clock.today()
    end
  end
end
