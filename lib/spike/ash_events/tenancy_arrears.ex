defmodule Spike.AshEvents.TenancyArrears do
  @moduledoc """
  Disposable read model (§7). Rebuildable from the log at any time; it is a
  report, NEVER the gate — the L7 decision reads the fold, not this table.
  """
  use Ash.Resource,
    domain: Spike.AshEvents,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "spike_ash_tenancy_arrears"
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
