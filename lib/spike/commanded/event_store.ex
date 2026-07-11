defmodule Spike.Commanded.EventStore do
  @moduledoc "Commanded's Postgres EventStore — the source of truth for Spike A."
  use EventStore, otp_app: :latchkey
end
