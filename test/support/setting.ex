# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.Setting do
  @moduledoc """
  An audited resource without multitenancy whose events still carry an organization
  in their metadata. AshEvents' default lock key gives every write of it the same
  shared key; the chain's generator gives it the organization's.
  """
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table "settings"
    repo AshEvents.Chain.TestRepo
  end

  events do
    event_log AshEvents.Chain.Test.EventLog
  end

  actions do
    defaults [:read, create: [:key]]
  end

  changes do
    change AshEvents.Chain.Test.StampPartition
  end

  attributes do
    uuid_primary_key :id
    attribute :key, :string, public?: true
  end
end
