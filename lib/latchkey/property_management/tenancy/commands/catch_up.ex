defmodule Latchkey.PropertyManagement.Tenancy.Commands.CatchUp do
  @moduledoc false
  # `as_of` is the sweep-through date (bounds which due dates accrue). `recorded_on`
  # rides the bitemporal envelope but the organic sweep books same-day: each swept-in
  # `RentFellDue` self-stamps recorded_on = occurred_on (issue #118). Divergence is
  # reserved for imported/transferred tenancies (#117).
  defstruct [:tenancy_id, :as_of, :recorded_on]

  @type t :: %__MODULE__{
          tenancy_id: String.t() | nil,
          as_of: Date.t() | nil,
          recorded_on: Date.t() | nil
        }
end
