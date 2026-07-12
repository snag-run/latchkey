defmodule Latchkey.PropertyManagement.Tenancy.Events.KeysReturned do
  @moduledoc false
  @derive Jason.Encoder
  # The raw input fact: possession was physically recovered on a date (ADR 0004 §1).
  # `occurred_on` is that keys-return date; `recorded_on` is the booking date. No
  # money of its own — the reckoning lives in the sibling `TenancySettled`.
  defstruct [:tenancy_id, :occurred_on, :recorded_on]
end
