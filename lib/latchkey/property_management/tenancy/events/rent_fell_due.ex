defmodule Latchkey.PropertyManagement.Tenancy.Events.RentFellDue do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:tenancy_id, :due_date, :amount_cents]
end
