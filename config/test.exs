# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

config :ash_events_chain,
  ecto_repos: [AshEvents.Chain.TestRepo],
  ash_domains: [AshEvents.Chain.Test.Domain]

config :ash_events_chain, AshEvents.Chain.TestRepo,
  database: "ash_events_chain_test#{System.get_env("MIX_TEST_PARTITION")}",
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# The retention worker's options, read when a job runs (test/support/retention_worker.ex).
config :ash_events_chain, AshEvents.Chain.Test.RetentionWorker, batch_size: 500

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
config :ash, :disable_async?, true

config :logger, level: :warning
