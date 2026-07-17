defmodule Latchkey.Simulation.SeedGeneration do
  @moduledoc """
  The **seed generation** — a single, monotonically-advancing counter that stamps every
  planned job with the seed it was planned under (ADR 0011 / spec
  `docs/spec/simulation-engine.md`, "Reset carries a seed generation"; issue #162).

  ## Why it exists — the reset-vs-claimed-job race

  Reset (#174) purges *scheduled* planned jobs and replans against a fresh seed. But a job
  Oban has already **claimed** (moved to `executing`) is past deletion, and would
  otherwise dispatch a stale command — a decision made against the *old* world — into the
  fresh seed. The generation closes that race without depending on purge timing:

    1. Reset **advances the generation first** (`advance/0`), *before* any purge/replan.
    2. The planner stamps the current generation onto each job and folds it into the
       Oban uniqueness key, so a lingering old-generation job never blocks the fresh
       enqueue (`Latchkey.Simulation.Planner`).
    3. The dumb runtime dispatch reads `current/0` and **no-ops any job whose stamped
       generation is behind it** (`Latchkey.Simulation.ScheduledEvent`) — the backstop
       for the already-claimed job.

  That advance→purge→replan ordering is the whole point: this ticket establishes the
  mechanism (storage, atomic advance, `current/0`); the reset cron (#174) drives it.

  ## Storage

  A single row in `sim_seed_generation`, pinned to `id = 0`. `advance/0` bumps it with a
  single atomic `UPDATE ... RETURNING`, so concurrent advances can never read-modify-write
  over each other. `current/0` reads the live value. The counter starts at `0`; a
  never-reset board runs the whole time at generation `0`.
  """
  alias Latchkey.Repo

  @doc """
  The current (live) seed generation.
  """
  @spec current() :: non_neg_integer()
  def current do
    %Postgrex.Result{rows: [[generation]]} =
      Repo.query!("SELECT generation FROM sim_seed_generation WHERE id = 0")

    generation
  end

  @doc """
  Atomically advance the seed generation by one, returning the new value.

  A single `UPDATE ... RETURNING` — the read and the write are one statement, so this is
  safe against a concurrent advance and never regresses. Reset (#174) must call this
  **before** purging + replanning, so the replan stamps the *new* generation while any
  already-claimed old-generation job is left stale.
  """
  @spec advance() :: non_neg_integer()
  def advance do
    %Postgrex.Result{rows: [[generation]]} =
      Repo.query!(
        "UPDATE sim_seed_generation SET generation = generation + 1 WHERE id = 0 RETURNING generation"
      )

    generation
  end
end
