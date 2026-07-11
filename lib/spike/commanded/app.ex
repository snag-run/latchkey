defmodule Spike.Commanded.App do
  @moduledoc """
  Commanded application. Not in the main supervision tree — started explicitly by
  the demo/seed tasks so the app still boots without the event-store DB present.
  """
  use Commanded.Application, otp_app: :latchkey

  router(Spike.Commanded.Router)
end
