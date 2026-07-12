defmodule Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy do
  @moduledoc false
  # `recorded_on` is the booking date; the aggregate edge fills it from
  # `Latchkey.Clock.today()` when the live path leaves it nil.
  #
  # `property_ref` is a non-PII, stable, opaque property id (e.g. `"prop-07"`) that
  # recurs across re-lets of the same premises (ADR 0008). It is log metadata for the
  # read side — it does not affect accrual or invariants. No names/addresses ever.
  defstruct [:tenancy_id, :property_ref, :rent_amount_cents, :cycle, :first_due_date, :recorded_on]
end
