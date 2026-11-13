# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

# The suite provisions its own database, so `mix test` works on a fresh server as
# well as after CI's `ash_postgres.create` and `ash_postgres.migrate`.
repo = AshEvents.Chain.TestRepo

_ = repo.__adapter__().storage_up(repo.config())
{:ok, _} = repo.start_link()

Ecto.Migrator.run(repo, Path.expand("priv/test_repo/migrations"), :up, all: true, log: false)

Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)

ExUnit.start()
