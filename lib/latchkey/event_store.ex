defmodule Latchkey.EventStore do
  @moduledoc "Commanded's Postgres EventStore — the source of truth for the write model (ADR 0003)."
  use EventStore, otp_app: :latchkey
end
