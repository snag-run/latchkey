defmodule Latchkey.PropertyManagement.Tenancy.Commands.GiveTerminationNotice do
  @moduledoc false
  defstruct [:tenancy_id, :termination_date, :given_on, :as_of]
end
