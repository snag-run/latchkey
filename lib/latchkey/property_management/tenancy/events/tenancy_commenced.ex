defmodule Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:tenancy_id, :rent_amount_cents, :cycle, :first_due_date]
end
