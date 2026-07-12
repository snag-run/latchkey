defmodule Latchkey.PropertyManagement.Tenancy.Commands.ReturnKeys do
  @moduledoc false
  # Records possession being recovered and closes the tenancy out. `keys_on` is the
  # keys-return date (event `occurred_on`); `recorded_on` is the booking date,
  # defaulted to `Clock.today()` at the edge. This slice is boundary-aligned: the
  # effective end date `E` is folded from the termination notice and catch-up clamps
  # at `E` (whole periods only — no mid-week pro-ration, no overstay yet).
  defstruct [:tenancy_id, :keys_on, :recorded_on]
end
