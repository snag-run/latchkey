defmodule Latchkey.Simulation.ResetWorker do
  @moduledoc """
  The **config-guarded destructive reset cron** (issue #174, ADR 0007 decision 3) — the
  monthly `Oban.Plugins.Cron` job that keeps the unattended demo store curated by resetting
  it to a fresh board anchored to the new `today`.

  ## Fails closed — the demo-reset guard

  The reset is destructive, so the worker is a **hard no-op unless it is explicitly enabled**.
  It reads the `:demo_reset_enabled` flag, which is set *only* in the deployed demo
  environment (`config/runtime.exs`, from `DEMO_RESET_ENABLED`); absent or false — every dev
  machine, CI, test, and a mis-scoped deploy — the worker touches nothing and returns `:ok`.
  Reset is a default-deny: a config regression can never fire it.

  ## What it drives (when enabled)

  `Latchkey.Simulation.Reset.reset_to_healthy!/1` — advances the seed generation (so an
  already-claimed old-generation job no-ops, issue #162), hard-deletes only the `tenancy-*`
  streams + the Accounts stream, truncates only their projections, then restarts the write
  side and reseeds + replans a board that is a pure function of `today`. The worker reads
  "now" once at the edge (`Clock.today/0`) and forwards it, keeping this the single
  wall-clock read-site for the reset (ADR 0005).

  The reset is idempotent (re-run, not repair), so an Oban retry after a partial failure
  simply re-runs it to a cleanly reseeded store.

  ## Subscription lifetime — one job process per reset

  `reset_to_healthy!/1` reseeds *after* it restarts the write side, and the seeder opens
  transient `EventStore.subscribe` subscriptions in the calling process. Because each
  monthly cron firing runs `perform/1` in its **own fresh Oban job process**, those
  subscriptions live and die with that one job — they are gone before the next reset ever
  terminates the `CommandedApp`, so they can never cascade a `:shutdown` into a subsequent
  reset. (The integration test reproduces this per-reset process boundary with an
  `isolated/1` task, mirroring production rather than papering over a linkage bug.)
  """
  use Oban.Worker, queue: :simulation, max_attempts: 3

  alias Latchkey.Clock
  alias Latchkey.Simulation.Reset

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if enabled?() do
      reset_fun().(today: Clock.today())
    end

    :ok
  end

  # The demo-reset guard: enabled only when the flag is explicitly `true`. Any other value
  # (the unset default, `false`, a stray string) fails closed.
  defp enabled?, do: Application.get_env(:latchkey, :demo_reset_enabled, false) == true

  # The reset invocation, overridable via config so the guard can be unit-tested without
  # driving a real wipe-and-reseed. Defaults to the production reset.
  defp reset_fun,
    do: Application.get_env(:latchkey, :demo_reset_fun, &Reset.reset_to_healthy!/1)
end
