defmodule Latchkey.Accounts.Events.PaymentReceived do
  @moduledoc false
  @derive Jason.Encoder
  # Accounts edge event: money actually received (domain-model.md §3).
  # `occurred_on` is the payment's received date (edge input `received_on`);
  # `recorded_on` is the booking date. `holder` is a `tenancy_ref` string, or the
  # `UNKNOWN` sentinel when Accounts can't yet attribute the money — UNKNOWN is
  # representable here but must never cross the seam into PM (ACL-1 refuses to
  # translate it; enforced in a later issue).
  defstruct [:payment_id, :amount_cents, :occurred_on, :recorded_on, :holder]

  @type t :: %__MODULE__{
          payment_id: String.t(),
          amount_cents: integer(),
          occurred_on: Date.t() | String.t(),
          recorded_on: Date.t() | String.t(),
          holder: String.t()
        }
end
