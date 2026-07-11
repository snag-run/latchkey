defmodule Spike.Commanded.Events.TerminationNoticeGiven do
  @moduledoc false
  @derive Jason.Encoder
  defstruct [:tenancy_id, :grounds, :termination_date, :given_on]
end
