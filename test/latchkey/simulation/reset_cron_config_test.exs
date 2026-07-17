defmodule Latchkey.Simulation.ResetCronConfigTest do
  @moduledoc """
  Guards the wiring of the reset-to-healthy cron (issue #174, ADR 0007 decision 3): the
  monthly `Oban.Plugins.Cron` entry exists, and the demo-reset guard fails closed by
  default (so the destructive job is a no-op everywhere but the deployed demo env).
  """
  use ExUnit.Case, async: true

  alias Latchkey.Simulation.ResetWorker

  test "the reset worker is wired as a monthly Oban cron" do
    crontab =
      :latchkey
      |> Application.fetch_env!(Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value(fn
        {Oban.Plugins.Cron, cron_opts} -> Keyword.fetch!(cron_opts, :crontab)
        _other -> nil
      end)

    assert {"@monthly", ResetWorker} in crontab
  end

  test "the demo-reset flag fails closed by default" do
    refute Application.get_env(:latchkey, :demo_reset_enabled, false) == true
  end
end
