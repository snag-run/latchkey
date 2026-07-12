defmodule Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy do
  @moduledoc false
  # `recorded_on` is the booking date; the aggregate edge fills it from
  # `Latchkey.Clock.today()` when the live path leaves it nil.
  defstruct [:tenancy_id, :rent_amount_cents, :cycle, :first_due_date, :recorded_on]
end
