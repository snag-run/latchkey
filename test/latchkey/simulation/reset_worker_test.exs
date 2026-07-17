defmodule Latchkey.Simulation.ResetWorkerTest do
  @moduledoc """
  The config-guarded reset cron's **guard** (issue #174, ADR 0007 decision 3), unit-tested
  at the worker seam. The reset itself is exercised end to end in
  `Latchkey.Simulation.ResetIntegrationTest`; here we prove only that the flag gates it —
  the destructive default-deny — with the reset invocation stubbed via `:demo_reset_fun`,
  so no real wipe runs.
  """
  use Latchkey.DataCase, async: false
  use Oban.Testing, repo: Latchkey.Repo

  alias Latchkey.Simulation.ResetWorker
  alias Latchkey.Simulation.SeedGeneration

  setup do
    # Record every reset invocation instead of driving a real reset.
    test = self()
    prev_fun = Application.get_env(:latchkey, :demo_reset_fun)
    prev_enabled = Application.get_env(:latchkey, :demo_reset_enabled)

    Application.put_env(:latchkey, :demo_reset_fun, fn opts -> send(test, {:reset, opts}) end)

    on_exit(fn ->
      restore(:demo_reset_fun, prev_fun)
      restore(:demo_reset_enabled, prev_enabled)
    end)

    :ok
  end

  test "no-ops (touches nothing) when the demo-reset flag is absent" do
    Application.delete_env(:latchkey, :demo_reset_enabled)
    before = SeedGeneration.current()

    assert :ok = perform_job(ResetWorker, %{})

    refute_received {:reset, _opts}
    # The reset advances the generation first, so an unchanged generation proves the guard
    # short-circuited before touching anything.
    assert SeedGeneration.current() == before
  end

  test "no-ops when the demo-reset flag is explicitly false" do
    Application.put_env(:latchkey, :demo_reset_enabled, false)

    assert :ok = perform_job(ResetWorker, %{})

    refute_received {:reset, _opts}
  end

  test "no-ops on a non-true value (fails closed, not merely on false)" do
    Application.put_env(:latchkey, :demo_reset_enabled, "true")

    assert :ok = perform_job(ResetWorker, %{})

    refute_received {:reset, _opts}
  end

  test "drives the reset with today when the flag is explicitly enabled" do
    Application.put_env(:latchkey, :demo_reset_enabled, true)

    assert :ok = perform_job(ResetWorker, %{})

    assert_received {:reset, opts}
    assert Keyword.fetch!(opts, :today) == Latchkey.Clock.today()
  end

  defp restore(key, nil), do: Application.delete_env(:latchkey, key)
  defp restore(key, value), do: Application.put_env(:latchkey, key, value)
end
