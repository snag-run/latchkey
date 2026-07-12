defmodule Latchkey.MixProject do
  use Mix.Project

  def project do
    [
      app: :latchkey,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      test_coverage: [tool: ExCoveralls]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Latchkey.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:oban, "~> 2.0"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:ash_postgres, "~> 2.0"},
      {:ash_phoenix, "~> 2.0"},
      {:ash, "~> 3.0"},
      # Event-sourcing foundation — raw Commanded + its Postgres EventStore (ADR 0003).
      {:commanded, "~> 1.4"},
      {:commanded_eventstore_adapter, "~> 1.4"},
      {:eventstore, "~> 1.4"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.6.15",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      # Time-zone database for DST-aware Australia/Sydney date resolution (Clock, ADR 0005).
      {:tz, "~> 0.28"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      "db.setup": ["ash.setup", "event_store.init --quiet"],
      "db.setup.quiet": ["ash.setup --quiet", "event_store.init --quiet"],
      setup: [
        "deps.get",
        # Provision both the AshPostgres app DB and Commanded's EventStore schema.
        "db.setup",
        "assets.setup",
        "assets.build",
        "run priv/repo/seeds.exs",
        # Point git at the committed pre-push gate (.githooks/pre-push). hooksPath
        # is per-clone local config, so each checkout wires it once via setup.
        "cmd git config core.hooksPath .githooks"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["db.setup.quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind latchkey", "esbuild latchkey"],
      "assets.deploy": [
        "tailwind latchkey --minify",
        "esbuild latchkey --minify",
        "phx.digest"
      ],
      # The full local gate. Enforced before every push by .githooks/pre-push
      # (wired per-clone by `mix setup`). Uses the non-mutating checks
      # (--check-unused, --check-formatted) that fail loud, rather than the
      # auto-fixing variants, so a green `mix precommit` is a real gate.
      # Audits run before the first compile on purpose: compiling in the same OS
      # process purges the Hex archive, after which `mix hex.audit` can no longer
      # be resolved. `hex.audit` runs before `deps.audit` because mix_audit
      # itself compiles when invoked, which is enough to purge the archive.
      precommit: [
        "deps.unlock --check-unused",
        "hex.audit",
        "deps.audit",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow --config",
        "db.setup.quiet",
        "coveralls"
      ]
    ]
  end
end
