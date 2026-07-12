defmodule Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded do
  @moduledoc false
  @derive Jason.Encoder
  # `occurred_on` is the payment's received date.
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :amount_cents, :source_payment_id]
end
