defmodule Latchkey.PropertyManagement.Timeline.Entry do
  @moduledoc """
  One typed row of a tenancy `Timeline` (ADR 0006 "Entry shape"). It is the return
  shape of the compute-on-read query — nothing is stored.

  `kind` is one of the event kinds that exist today: `:commenced`, `:rent_fell_due`,
  `:payment`, `:notice_given` (reversal / notice-voided / keys-returned / settled are
  later fidelity slices — #49/#50).

  Money rows (`:rent_fell_due`, `:payment`) fill `debit_cents` / `credit_cents`;
  lifecycle markers (`:commenced`, `:notice_given`) leave them `nil` but still carry
  `balance_snapshot_cents` and `days_behind` — a notice row's balance + days-behind
  *is* the L7 arrears evidence.

  Both `occurred_on` (primary/sort date) and `recorded_on` (when booked) are always
  present; the presentation layer mutes `recorded_on` when it equals `occurred_on`
  (ADR 0006 §4) — the data supports that render hint by exposing both values.
  """

  @type kind :: :commenced | :rent_fell_due | :payment | :notice_given

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
          kick_in_date: Date.t() | nil
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
    :kick_in_date
  ]
end
