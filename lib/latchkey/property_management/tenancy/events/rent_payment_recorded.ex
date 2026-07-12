defmodule Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded do
  @moduledoc false
  @derive Jason.Encoder
  # `occurred_on` is the payment's received date (a reversal's reversed date).
  #
  # `amount_cents` is signed: a forward receipt is positive, a reversal is negative
  # (ADR 0006 §7 — a reversal is a compensating entry the fold absorbs and the
  # timeline re-expands into the debit column). `reason` and `reverses` are the
  # reversal-only fields ACL-1 propagates from the Accounts `PaymentReversed`
  # (`reverses` = the original payment id this undoes); both stay `nil` on the
  # forward path, so existing forward-path events still fold unchanged.
  defstruct [
    :tenancy_id,
    :occurred_on,
    :recorded_on,
    :amount_cents,
    :source_payment_id,
    :reason,
    :reverses
  ]
end
