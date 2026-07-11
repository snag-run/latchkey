defmodule Latchkey.PropertyManagement.Tenancy.Commands.RecordPayment do
  @moduledoc false
  defstruct [:tenancy_id, :amount_cents, :received_on, :source_payment_id]
end
