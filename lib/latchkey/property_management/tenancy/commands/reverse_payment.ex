defmodule Latchkey.PropertyManagement.Tenancy.Commands.ReversePayment do
  @moduledoc false
  # ACL-1's reversal-path command (the negative sibling of `RecordPayment`).
  #
  # `reversed_on` is the reversal's real-world date (event `occurred_on`);
  # `recorded_on` is the booking date, defaulted to `Clock.today()` at the edge.
  # `amount_cents` is negative (the compensating amount). `source_payment_id` is the
  # reversal's *own* payment id — the idempotency key for the reversal itself.
  # `reverses` links the original payment being undone (P2: the aggregate rejects a
  # reversal whose `reverses` it never recorded); `reason` is carried onto the row.
  defstruct [
    :tenancy_id,
    :amount_cents,
    :reversed_on,
    :source_payment_id,
    :recorded_on,
    :reason,
    :reverses
  ]
end
