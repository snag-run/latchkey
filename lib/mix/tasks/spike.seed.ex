defmodule Mix.Tasks.Spike.Seed do
  @shortdoc "Seed the ES bake-off scenarios into a backend: ash | commanded | both"
  @moduledoc """
  Seeds realistic tenancies (see `Spike.Seeds`) into a chosen ES foundation and
  prints the resulting arrears read model + how the L7 gate would rule.

      mix spike.seed ash
      mix spike.seed commanded
      mix spike.seed both     # default; both yield identical projections (parity)
  """
  use Mix.Task

  @requirements ["app.start"]

  def run(args) do
    # Commanded + Ash emit copious debug SQL; keep the report readable.
    Logger.configure(level: :info)
    backend = List.first(args) || "both"

    case backend do
      "ash" ->
        Spike.Seeds.seed_ash()

      "commanded" ->
        start_commanded()
        Spike.Seeds.seed_commanded()

      "both" ->
        Spike.Seeds.seed_ash()
        start_commanded()
        Spike.Seeds.seed_commanded()

      other ->
        Mix.raise("unknown backend #{inspect(other)} — use ash | commanded | both")
    end

    report(backend)
  end

  defp start_commanded do
    ensure_started(fn -> Spike.Commanded.App.start_link() end)
    ensure_started(fn -> Spike.Commanded.ArrearsProjector.start_link() end)
  end

  defp ensure_started(fun) do
    case fun.() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp report(backend) do
    address = Map.new(Spike.Seeds.scenarios(), &{&1.id, &1.address})

    rows =
      Spike.AshEvents.TenancyArrears
      |> Ash.read!()
      |> Enum.filter(&String.starts_with?(&1.tenancy_id, "seed-"))
      |> Enum.sort_by(& &1.tenancy_id)

    IO.puts(
      "\n  ES bake-off seed — arrears read model (backend: #{backend}, as_of #{Spike.Seeds.as_of()})\n"
    )

    IO.puts(
      "  #{pad("tenancy", 26)}#{pad("balance", 12)}#{pad("days_behind", 13)}L7 termination gate"
    )

    IO.puts("  #{String.duplicate("─", 70)}")

    for r <- rows do
      gate = if r.days_behind >= 14, do: "ACCEPT (>=14d arrears)", else: "refuse (<14d)"

      IO.puts(
        "  #{pad(address[r.tenancy_id], 26)}#{pad("$" <> money(r.balance_cents), 12)}#{pad(to_string(r.days_behind), 13)}#{gate}"
      )
    end

    IO.puts("")
  end

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
  defp money(cents), do: :erlang.float_to_binary(cents / 100, decimals: 2)
end
