defmodule Latchkey.Repo.Migrations.CreateSimSeedGeneration do
  @moduledoc """
  The **seed-generation counter** (spec `docs/spec/simulation-engine.md`, "Reset carries
  a seed generation"; issue #162). A single-row, monotonically-advancing integer that
  reset (#174) bumps *before* it purges + replans, so a job Oban has already claimed
  under the old generation can be recognised as stale and no-op'd.

  Singleton by construction: a fixed `id = 0` primary key with a `CHECK` that pins it,
  and exactly one seed row (`generation = 0`). The dev/test DB is seed-regenerated, so no
  backfill is needed — the seed row *is* the baseline.
  """
  use Ecto.Migration

  def up do
    create table(:sim_seed_generation, primary_key: false) do
      add :id, :smallint, primary_key: true, null: false, default: 0
      add :generation, :bigint, null: false, default: 0
    end

    create constraint(:sim_seed_generation, :sim_seed_generation_singleton, check: "id = 0")

    execute "INSERT INTO sim_seed_generation (id, generation) VALUES (0, 0)"
  end

  def down do
    drop table(:sim_seed_generation)
  end
end
