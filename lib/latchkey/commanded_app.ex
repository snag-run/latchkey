defmodule Latchkey.CommandedApp do
  @moduledoc """
  The Commanded application — hosts aggregates, routes commands, owns the
  EventStore connection. Dispatch commands through `Latchkey.CommandedApp.dispatch/2`.
  """
  use Commanded.Application, otp_app: :latchkey

  router(Latchkey.Router)
end
