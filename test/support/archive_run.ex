# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.ArchiveRun do
  @moduledoc """
  The run ledger, under a host policy: recording a step needs an actor, so the
  retention engine must pass the one the host allows.
  """
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  use AshEvents.Chain.Resources,
      {:archive_run,
       log: AshEvents.Chain.Test.EventLog,
       table: "audit_archive_runs",
       repo: AshEvents.Chain.TestRepo,
       chain_attribute: :chain_organization_id}

  policies do
    policy action_type(:create) do
      authorize_if actor_attribute_equals(:role, :retention)
    end

    policy action_type(:read) do
      authorize_if always()
    end
  end
end
