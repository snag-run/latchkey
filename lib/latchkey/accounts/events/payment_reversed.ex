defmodule Latchkey.Accounts.Events.PaymentReversed do
  @moduledoc false
  @derive Jason.Encoder
  # Accounts edge event: a compensating reversal (domain-model.md §3) — never edit
  # a posted `PaymentReceived`. `reverses` is the `payment_id` being reversed;
  # `amount_cents` is negative (the compensating amount); `occurred_on` is the
  # reversed date (edge input `reversed_on`); `recorded_on` is the booking date.
  # Reallocation is not a distinct event: it is a reversal on the wrong holder plus
  # a fresh `PaymentReceived` on the right one.
  defstruct [:payment_id, :reverses, :amount_cents, :occurred_on, :recorded_on, :reason]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          reverses: String.t(),
          amount_cents: integer(),
          occurred_on: Date.t() | String.t(),
          recorded_on: Date.t() | String.t(),
          reason: String.t()
        }
end
