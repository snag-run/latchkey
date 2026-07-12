defmodule Latchkey.PropertyManagement.Tenancy.Events.RentFellDue do
  @moduledoc false
  @derive Jason.Encoder
  # `occurred_on` is the rent's due date; `recorded_on` lags it for lazy accrual
  # (a swept-in catch-up tick has recorded_on >= occurred_on — not backdating).
  #
  # `period_from`/`period_to` name the exact span the charge covers as a half-open
  # interval `[period_from, period_to)` (domain-model §3): `period_from` inclusive,
  # `period_to` exclusive, so adjacent periods abut without double-counting a day. A
  # whole period spans `[due, due + 7)`; the pro-rated boundary period at exit spans
  # `[period_from, E)` — `period_to` is E, so E is never charged by the boundary tick.
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :amount_cents, :period_from, :period_to]
end
