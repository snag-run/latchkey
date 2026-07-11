defmodule Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:tenancy_id, :grounds, :termination_date, :given_on]
end
