# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.EventLog do
  @moduledoc "The host's audit log, chained per organization, with an archive."
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

  use AshEvents.Chain.Resources,
      {:chained_log,
       partition: :organization_id,
       partition_metadata_key: "organization_id",
       archive_table: "audit_event_archive",
       archive_run: AshEvents.Chain.Test.ArchiveRun}

  postgres do
    table "audit_events"
    repo AshEvents.Chain.TestRepo
  end

  event_log do
    primary_key_type Ash.Type.UUIDv7
    persist_actor_primary_key :user_id, AshEvents.Chain.Test.User
    advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator
  end

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end

  actions do
    defaults [:read]
  end
end
