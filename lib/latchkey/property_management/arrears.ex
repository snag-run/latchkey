defmodule Latchkey.PropertyManagement.Arrears do
  @moduledoc """
  Arrears read model (domain-model.md §7): `{tenancy_id, balance_cents,
  oldest_unpaid_due_date}`. Derived, disposable, rebuildable from the event log.
  It is a **report** — never the L7 gate, which reads the aggregate fold.

  Only `oldest_unpaid_due_date` is persisted (event-driven). `days_behind` is
  **computed on read** as `Clock.today() − oldest_unpaid_due_date` in Sydney
  (ADR 0005 decision 6) — so an idle arrears tenant's counter climbs day-to-day
  with no new event, and the projection never re-stamps a stored number.
  """
  use Ash.Resource,
    domain: Latchkey.PropertyManagement,
    data_layer: AshPostgres.DataLayer

  alias Latchkey.Clock

  postgres do
    table "pm_tenancy_arrears"
    repo Latchkey.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :upsert do
      accept [:tenancy_id, :balance_cents, :oldest_unpaid_due_date]
      upsert? true
      upsert_identity :tenancy
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :tenancy_id, :string, allow_nil?: false, public?: true
    attribute :balance_cents, :integer, public?: true
    attribute :oldest_unpaid_due_date, :date, public?: true
  end

  identities do
    identity :tenancy, [:tenancy_id]
  end

  @doc """
  Elapsed calendar days from the oldest unpaid due date, as of `today`
  (defaults to the live Sydney date via `Clock.today/0`). `0` when paid up.

  Pure over its `today` argument — the wall clock is read only at the edge (the
  default), so callers can pass an explicit date for deterministic reads/tests.
  """
  @spec days_behind(t(), Date.t()) :: non_neg_integer()
  def days_behind(record, today \\ Clock.today())
  def days_behind(%__MODULE__{oldest_unpaid_due_date: nil}, _today), do: 0

  def days_behind(%__MODULE__{oldest_unpaid_due_date: %Date{} = due}, %Date{} = today),
    do: max(0, Date.diff(today, due))
end
