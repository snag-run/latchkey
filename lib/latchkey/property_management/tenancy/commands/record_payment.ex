defmodule Latchkey.PropertyManagement.Tenancy.Commands.RecordPayment do
  @moduledoc false
  # `received_on` is the payment's real-world date (event `occurred_on`);
  # `recorded_on` is the booking date, defaulted to `Clock.today()` at the edge.
  defstruct [:tenancy_id, :amount_cents, :received_on, :source_payment_id, :recorded_on]
end
