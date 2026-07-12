defmodule Latchkey.Simulation.Directory do
  @moduledoc """
  The **Directory** read model (ADR 0008 Decision 1) — a disposable,
  **non-event-sourced** map of `tenancy_id → {tenant_name, property_address}`. It is
  the home for identity **PII**, kept deliberately **out of the immutable, public
  event log**: regenerable, erasable, never part of the evidence chain.

  Unlike `Latchkey.PropertyManagement.Arrears` (a projection folded from the log by a
  Commanded handler), the Directory is populated by a **direct Ash upsert at seed
  time** — no event, no stream. It shares the same Postgres repo/schema as `Arrears`
  but lives in the separate `Latchkey.Simulation` domain because it is throwaway demo
  plumbing, not a property-management read model.

  ## Render / merge contract (for the inspector, #81)

  The inspector resolves identity for an event row by an **in-Elixir keyed merge**,
  never a cross-schema join and never identity off the raw log:

    * the **tenant** side comes from this Directory, looked up by `tenancy_id`;
    * the **property** side comes from the event's own non-PII `property_ref`
      (carried on `TenancyCommenced`) — and, for display, this Directory's
      `property_address` for that tenancy;
    * the **ledger** side (status/balance/days-behind) comes from the `Arrears` row
      for the same `tenancy_id`.

  Merge these three in Elixir keyed by `tenancy_id`. The raw log never carries a name
  or address, so the public `/inspector` can render every stored event without
  exposing PII (ADR 0008 invariant).
  """
  use Ash.Resource,
    domain: Latchkey.Simulation,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "sim_tenancy_directory"
    repo Latchkey.Repo
  end

  actions do
    defaults [:read, :destroy]

    # Direct upsert — NOT event-sourced. The seeder writes one row per tenancy
    # (idempotent on `tenancy_id`) regardless of whether the tenancy was freshly
    # seeded or skipped, so a re-seed still populates identity.
    create :upsert do
      accept [:tenancy_id, :tenant_name, :property_address]
      upsert? true
      upsert_identity :tenancy
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :tenancy_id, :string, allow_nil?: false, public?: true

    # Human-legible display identity (PII). Off-log by design.
    attribute :tenant_name, :string, public?: true
    attribute :property_address, :string, public?: true
  end

  identities do
    identity :tenancy, [:tenancy_id]
  end
end
