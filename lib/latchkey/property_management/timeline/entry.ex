defmodule Latchkey.PropertyManagement.Timeline.Entry do
  @moduledoc """
  One typed row of a tenancy `Timeline` (ADR 0006 "Entry shape"). It is the return
  shape of the compute-on-read query — nothing is stored.

  `kind` is one of the event kinds that exist today: `:commenced`, `:rent_fell_due`,
  `:payment`, `:reversal`, `:notice_given`, `:keys_returned`, `:settled`
  (notice-voided is a later notice-fidelity slice).

  Money rows (`:rent_fell_due`, `:payment`, `:reversal`) fill `debit_cents` /
  `credit_cents`; lifecycle markers (`:commenced`, `:notice_given`, `:keys_returned`,
  `:settled`) leave them `nil` but still carry `balance_snapshot_cents` and
  `days_behind` — a notice row's balance + days-behind *is* the L7 arrears evidence.

  The `:keys_returned` marker dates the moment possession was recovered. The `:settled`
  marker is the closing punchline: its `balance_snapshot_cents` **is** the final
  reckoning (signed — a debt when positive, a refund owed when negative), so there is no
  separate "final balance" field to drift from the ledger (ADR 0006 §5). Post-Terminal
  (P4) payments render as ordinary credit rows **below** the settlement row and move the
  running balance without altering the immutable settlement snapshot.

  A `:reversal` is a **negative** `RentPaymentRecorded` re-expanded into the **debit**
  column at its own `occurred_on` (the reversed date), restoring the running balance
  (ADR 0006 §7). `reason` explains *why* (dishonoured, chargeback) and `reverses` links
  the original payment it undoes; both are `nil` on the forward `:payment` path. The
  original credit row is never mutated or hidden — correction by compensation.

  Both `occurred_on` (primary/sort date) and `recorded_on` (when booked) are always
  present; the presentation layer mutes `recorded_on` when it equals `occurred_on`
  (ADR 0006 §4) — the data supports that render hint by exposing both values.
  """

  @type kind ::
          :commenced
          | :rent_fell_due
          | :payment
          | :reversal
          | :notice_given
          | :keys_returned
          | :settled

  @type t :: %__MODULE__{
          tenancy_id: String.t(),
          kind: kind(),
          occurred_on: Date.t(),
          recorded_on: Date.t(),
          description: String.t(),
          debit_cents: non_neg_integer() | nil,
          credit_cents: non_neg_integer() | nil,
          balance_snapshot_cents: integer(),
          days_behind: non_neg_integer(),
          period_from: Date.t() | nil,
          period_to: Date.t() | nil,
          kick_in_date: Date.t() | nil,
          reason: String.t() | nil,
          reverses: String.t() | nil
        }

  defstruct [
    :tenancy_id,
    :kind,
    :occurred_on,
    :recorded_on,
    :description,
    :debit_cents,
    :credit_cents,
    :balance_snapshot_cents,
    :days_behind,
    :period_from,
    :period_to,
    :kick_in_date,
    :reason,
    :reverses
  ]
end
