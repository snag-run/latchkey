defmodule Latchkey.PropertyManagement.Tenancy.Events.TenancySettled do
  @moduledoc false
  @derive Jason.Encoder
  # The computed reckoning + Terminal transition (ADR 0004 §1–§2). Carries **no money
  # of its own** — `final_balance_cents` is a signed *snapshot* of the fold
  # (Σ charges − Σ payments) frozen at settlement: negative = refund owed to the
  # tenant, positive = debt. `occurred_on` is the settlement date; `recorded_on` the
  # booking date.
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :final_balance_cents]
end
