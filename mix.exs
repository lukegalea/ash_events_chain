# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.MixProject do
  use Mix.Project

  @version "0.1.0"

  @source_url "https://github.com/lukegalea/ash_events_chain"

  @description """
  A tamper-evident hash chain for an AshEvents event log: chain and immutability
  triggers from one SQL source, a verifier that reads the hot table and its
  archive as one chain, and a verified hot-to-archive retention move with a run
  ledger.
  """

  def project do
    [
      app: :ash_events_chain,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: &docs/0,
      description: @description,
      source_url: @source_url,
      homepage_url: @source_url,
      consolidate_protocols: Mix.env() != :test,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.create": :test,
        "test.migrate": :test,
        "test.drop": :test,
        "test.generate_migrations": :test,
        "test.check_migrations": :test,
        "test.reset": :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The package owns no processes. The retention worker runs on the host's Oban,
  # and every resource rides the host's repo.
  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp package do
    [
      maintainers: ["Luke Galea"],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE LICENSE.license LICENSES
        documentation usage-rules.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        {"README.md", title: "Home"},
        "documentation/topics/adopting-an-existing-chain.md",
        "CHANGELOG.md"
      ],
      groups_for_extras: [
        Topics: ~r'documentation/topics',
        About: ["CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Host API": [
          AshEvents.Chain,
          AshEvents.Chain.Resources,
          AshEvents.Chain.Retention,
          AshEvents.Chain.RetentionWorker,
          AshEvents.Chain.LockKeyGenerator
        ],
        Internals: [
          AshEvents.Chain.Extension,
          AshEvents.Chain.Info,
          AshEvents.Chain.SQL,
          AshEvents.Chain.Transformers.DefineChain,
          AshEvents.Chain.Preparations.ChainOrder
        ]
      ]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.34"},
      {:ash_postgres, "~> 2.14"},
      {:ash_events, "~> 0.8"},
      {:spark, "~> 2.7"},
      # Retention reports each chain it drains (`AshEvents.Chain.Retention`).
      {:telemetry, "~> 1.0"},
      # Only `AshEvents.Chain.RetentionWorker` uses it, and only in the host that
      # defines a worker with it.
      {:oban, "~> 2.0", optional: true},

      # Dev / test
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:simple_sat, "~> 0.1", only: [:dev, :test]},
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      # The Spark tasks the shared CI runs (`spark.formatter`, `spark.cheat_sheets`)
      # and its `igniter.upgrade` step need it.
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.37", only: [:dev], runtime: false},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "test.generate_migrations": "ash_postgres.generate_migrations",
      "test.check_migrations": "ash_postgres.generate_migrations --check",
      "test.migrate": "ash_postgres.migrate",
      "test.create": "ash_postgres.create",
      "test.reset": ["test.drop", "test.create", "test.migrate"],
      "test.drop": "ash_postgres.drop",
      credo: "credo --strict",
      "spark.formatter": "spark.formatter --extensions AshEvents.Chain.Extension",
      "spark.cheat_sheets": "spark.cheat_sheets --extensions AshEvents.Chain.Extension"
    ]
  end
end
