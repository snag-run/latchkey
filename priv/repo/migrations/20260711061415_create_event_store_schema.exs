defmodule Latchkey.Repo.Migrations.CreateEventStoreSchema do
  @moduledoc """
  Creates the `event_store` schema used by Commanded's Postgres EventStore
  (ADR 0003). The event store shares the Repo's database but keeps its tables in
  a dedicated schema. EventStore's own `init`/`migrate` tasks populate that
  schema but do not create it, so we create it here as part of the database
  structure — this migration runs before `event_store.init` in every environment
  (dev/test via `ash.setup`, prod via `Latchkey.Release.migrate/0`).
  """
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS event_store")
  end

  def down do
    execute("DROP SCHEMA IF EXISTS event_store CASCADE")
  end
end
