defmodule Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven do
  @moduledoc false
  @derive Jason.Encoder
  # `occurred_on` is the notice's served/given date. The kick-in date
  # (`termination_date`) stays payload — it is not the envelope date (ADR 0006 §3).
  defstruct [:tenancy_id, :occurred_on, :recorded_on, :grounds, :termination_date]
end
