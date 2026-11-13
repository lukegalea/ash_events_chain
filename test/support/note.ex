# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.Note do
  @moduledoc "A tenant-scoped audited resource: its events chain per organization."
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table "notes"
    repo AshEvents.Chain.TestRepo
  end

  events do
    event_log AshEvents.Chain.Test.EventLog
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
  end

  actions do
    defaults [:read, create: [:body], update: [:body]]
  end

  changes do
    change AshEvents.Chain.Test.StampPartition
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true
  end
end
