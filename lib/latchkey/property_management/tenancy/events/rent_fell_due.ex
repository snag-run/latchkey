defmodule Latchkey.PropertyManagement.Tenancy.Events.RentFellDue do
  @moduledoc false
  @derive Jason.Encoder
  # `occurred_on` is the rent's due date; `recorded_on` lags it for lazy accrual
  # (a swept-in catch-up tick has recorded_on >= occurred_on — not backdating).
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :amount_cents]
end
