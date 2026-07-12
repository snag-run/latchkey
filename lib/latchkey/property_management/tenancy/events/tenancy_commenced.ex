defmodule Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced do
  @moduledoc false
  @derive Jason.Encoder
  # Bitemporal envelope (occurred_on/recorded_on) + payload. `occurred_on` is the
  # commencement date; `first_due_date` is the distinct forward-looking accrual
  # anchor the fold uses to schedule future `RentFellDue` sweeps.
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :rent_amount_cents, :cycle, :first_due_date]
end
