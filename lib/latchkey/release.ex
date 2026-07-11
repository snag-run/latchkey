defmodule Latchkey.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :latchkey

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    init_event_stores()
  end

  # Create/upgrade the Commanded EventStore schema (ADR 0003). The event store
  # is its own logical database, distinct from the Ash/Ecto repo, and its tables
  # are managed by EventStore's own tasks rather than Ecto migrations. Both are
  # idempotent, so this is safe to run on every deploy.
  defp init_event_stores do
    {:ok, _} = Application.ensure_all_started(:postgrex)

    for event_store <- Application.fetch_env!(@app, :event_stores) do
      config = event_store.config()
      :ok = EventStore.Tasks.Init.exec(config, quiet: true)
      _ = EventStore.Tasks.Migrate.exec(config, quiet: true)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
