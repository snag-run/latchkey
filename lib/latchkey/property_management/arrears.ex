defmodule Latchkey.PropertyManagement.Arrears do
  @moduledoc """
  Arrears read model (domain-model.md §7): `{tenancy_id, balance_cents, days_behind,
  oldest_unpaid_due_date, as_of}`. Derived, disposable, rebuildable from the event
  log. It is a **report** — never the L7 gate, which reads the aggregate fold.
  """
  use Ash.Resource,
    domain: Latchkey.PropertyManagement,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "pm_tenancy_arrears"
    repo Latchkey.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:tenancy_id, :balance_cents, :days_behind, :oldest_unpaid_due_date, :as_of]
      upsert? true
      upsert_identity :tenancy
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :tenancy_id, :string, allow_nil?: false, public?: true
    attribute :balance_cents, :integer, public?: true
    attribute :days_behind, :integer, public?: true
    attribute :oldest_unpaid_due_date, :date, public?: true
    attribute :as_of, :date, public?: true
  end

  identities do
    identity :tenancy, [:tenancy_id]
  end
end
