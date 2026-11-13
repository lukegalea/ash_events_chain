# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.LegacyLog do
  @moduledoc """
  A log whose existing rows were hashed over a different column list than the
  default: no `version`, no actor, no `changed_attributes`, `metadata` before
  `data`, and an `as_of` column left out of the digest when it is NULL. It has no
  archive, so its immutability trigger refuses every delete.
  """
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

  use AshEvents.Chain.Resources,
      {:chained_log,
       partition: :organization_id,
       partition_metadata_key: "organization_id",
       chain_function: "legacy_audit_chain",
       immutable_function: "legacy_audit_immutable",
       digest_columns: [
         :sequence,
         :id,
         :record_id,
         :occurred_at,
         :resource,
         :action,
         :action_type,
         :organization_id,
         :metadata,
         :data,
         {:as_of, :omit_nil}
       ]}

  postgres do
    table "legacy_events"
    repo AshEvents.Chain.TestRepo
  end

  event_log do
    advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator
  end

  actions do
    defaults [:read]
  end

  attributes do
    # The application time a host recorded before AshEvents could.
    attribute :as_of, :utc_datetime_usec, public?: false
  end
end
