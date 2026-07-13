defmodule Latchkey.PropertyManagement.Tenancy.Events.RentFellDue do
  @moduledoc false
  @derive Jason.Encoder
  # `occurred_on` is the rent's due date. For system-managed accrual `recorded_on ==
  # occurred_on` — the tick books on its own due date (issue #118). `recorded_on >
  # occurred_on` only for an imported/transferred tenancy whose history is rebuilt (#117).
  #
  # `period_from`/`period_to` name the exact span the charge covers as a half-open
  # interval `[period_from, period_to)` (domain-model §3): `period_from` inclusive,
  # `period_to` exclusive, so adjacent periods abut without double-counting a day. A
  # whole period spans `[due, due + 7)`; the pro-rated boundary period at exit spans
  # `[period_from, E)` — `period_to` is E, so E is never charged by the boundary tick.
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :amount_cents, :period_from, :period_to]
end
