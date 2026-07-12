defmodule Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced do
  @moduledoc false
  @derive Jason.Encoder
  # Bitemporal envelope (occurred_on/recorded_on) + payload. `occurred_on` is the
  # commencement date; `first_due_date` is the distinct forward-looking accrual
  # anchor the fold uses to schedule future `RentFellDue` sweeps.
  #
  # `property_ref` is the non-PII, stable, opaque property id (ADR 0008) carried on
  # the log alongside `tenancy_id` — the non-PII allowlist. It recurs across re-lets
  # so "these successive tenancies are the same premises" is a first-class log fact.
  # No tenant names or addresses are ever written to the log.
  defstruct [
    :tenancy_id,
    :property_ref,
    :occurred_on,
    :recorded_on,
    :rent_amount_cents,
    :cycle,
    :first_due_date
  ]
end
