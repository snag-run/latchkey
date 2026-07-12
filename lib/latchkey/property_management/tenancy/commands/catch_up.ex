defmodule Latchkey.PropertyManagement.Tenancy.Commands.CatchUp do
  @moduledoc false
  # `as_of` is the sweep-through date (bounds which due dates accrue);
  # `recorded_on` is the booking date, defaulted to `Clock.today()` at the edge.
  # A swept-in `RentFellDue` therefore carries recorded_on >= occurred_on.
  defstruct [:tenancy_id, :as_of, :recorded_on]
end
