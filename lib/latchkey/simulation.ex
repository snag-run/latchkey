defmodule Latchkey.Simulation do
  @moduledoc """
  The **Simulation** bounded context — disposable, non-event-sourced plumbing that
  makes the learning sim legible without ever touching the immutable event log.

  It is a second Ash domain (alongside `Latchkey.PropertyManagement`, ADR 0008) whose
  only resource today is the `Directory` read model: the home for identity **PII**
  (tenant names + property addresses) kept deliberately **off the append-only log**.
  The seed catalogue, behaviour engine and identity derivation also live under this
  namespace as plain modules; the Ash domain holds only the persisted read model.
  """
  use Ash.Domain

  resources do
    resource Latchkey.Simulation.Directory
  end
end
