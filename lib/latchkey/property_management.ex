defmodule Latchkey.PropertyManagement do
  @moduledoc """
  Property Management bounded context (domain-model.md §2) — the deep context that
  owns the tenancy, the rent schedule, and arrears.

  The write side is the event-sourced `Tenancy` aggregate (Commanded); this Ash
  domain holds the **read models** (disposable projections rebuilt from the log).
  """
  use Ash.Domain

  resources do
    resource Latchkey.PropertyManagement.Arrears
  end
end
