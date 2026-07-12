defmodule Latchkey.Router do
  @moduledoc "Routes commands to their aggregate. One line per aggregate as the domain grows."
  use Commanded.Commands.Router

  alias Latchkey.PropertyManagement.Tenancy.Aggregate

  alias Latchkey.PropertyManagement.Tenancy.Commands.{
    CatchUp,
    CommenceTenancy,
    GiveTerminationNotice,
    RecordPayment,
    ReturnKeys,
    ReversePayment
  }

  identify(Aggregate, by: :tenancy_id, prefix: "tenancy-")

  dispatch(
    [CommenceTenancy, RecordPayment, ReversePayment, CatchUp, GiveTerminationNotice, ReturnKeys],
    to: Aggregate
  )
end
