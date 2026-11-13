# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.LegacyNote do
  @moduledoc "An audited resource writing to the legacy-digest log."
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events]

  postgres do
    table "legacy_notes"
    repo AshEvents.Chain.TestRepo
  end

  events do
    event_log AshEvents.Chain.Test.LegacyLog
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
