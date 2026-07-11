defmodule Spike.AshEvents do
  @moduledoc """
  Spike B — events-as-resources in pure Ash (no Commanded).

  The event log is an ordinary Ash resource (`Event`); the aggregate is a plain
  module (`Tenancy`) that loads the stream, folds it via `Spike.TenancyCore`,
  decides, and appends. The read model (`TenancyArrears`) is a second, disposable
  Ash resource. See `spike/README.md`.
  """
  use Ash.Domain

  resources do
    resource Spike.AshEvents.Event
    resource Spike.AshEvents.TenancyArrears
  end
end
