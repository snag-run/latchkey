defmodule Latchkey.PropertyManagement.Tenancy.Commands.GiveTerminationNotice do
  @moduledoc false
  # `given_on` is the served date (event `occurred_on`); `termination_date` is the
  # kick-in payload; `as_of` is the arrears-assessment/sweep-through date; and
  # `recorded_on` is the booking date, defaulted to `Clock.today()` at the edge.
  defstruct [:tenancy_id, :termination_date, :given_on, :as_of, :recorded_on]
end
