defmodule Latchkey.PropertyManagement.Tenancy.State do
  @moduledoc """
  The consistency boundary (domain-model.md §4): the folded state the `Tenancy`
  aggregate holds to enforce its rules. Derived reads (balance, days_behind,
  oldest_unpaid_due_date) are computed from this in `Latchkey.PropertyManagement.Tenancy`.
  """
  defstruct status: :pending,
            tenancy_id: nil,
            rent_amount_cents: nil,
            cycle: nil,
            first_due_date: nil,
            due_through: nil,
            charges: [],
            payments_total_cents: 0,
            applied_payment_ids: MapSet.new(),
            # Effective end date E, folded from the termination notice (the clamp for
            # end-date-aware catch-up). `keys_returned_on`/`final_balance_cents` are
            # the exit reckoning captured at settlement (final_balance is a frozen
            # snapshot, not the live balance).
            effective_end_date: nil,
            keys_returned_on: nil,
            final_balance_cents: nil
end
