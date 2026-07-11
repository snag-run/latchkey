defmodule Spike.Commanded.Events.RentPaymentRecorded do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:tenancy_id, :amount_cents, :received_on, :source_payment_id]
end
