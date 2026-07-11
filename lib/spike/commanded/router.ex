defmodule Spike.Commanded.Router do
  @moduledoc false
  use Commanded.Commands.Router

  alias Spike.Commanded.Commands.{CatchUp, CommenceTenancy, GiveTerminationNotice, RecordPayment}
  alias Spike.Commanded.TenancyAggregate

  identify(TenancyAggregate, by: :tenancy_id, prefix: "tenancy-")

  dispatch([CommenceTenancy, RecordPayment, CatchUp, GiveTerminationNotice],
    to: TenancyAggregate
  )
end
