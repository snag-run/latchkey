defmodule Latchkey.Router do
  @moduledoc "Routes commands to their aggregate. One line per aggregate as the domain grows."
  use Commanded.Commands.Router

  alias Latchkey.PropertyManagement.Tenancy.Aggregate

  alias Latchkey.PropertyManagement.Tenancy.Commands.{
    CatchUp,
    CommenceTenancy,
    GiveTerminationNotice,
    RecordPayment
  }

  identify(Aggregate, by: :tenancy_id, prefix: "tenancy-")

  dispatch([CommenceTenancy, RecordPayment, CatchUp, GiveTerminationNotice], to: Aggregate)
end
