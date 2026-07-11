defmodule Spike.Commanded.Commands.CommenceTenancy do
  @moduledoc false
  defstruct [:tenancy_id, :rent_amount_cents, :cycle, :first_due_date]
end
