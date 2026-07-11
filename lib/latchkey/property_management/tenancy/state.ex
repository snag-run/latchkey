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
            applied_payment_ids: MapSet.new()
end
