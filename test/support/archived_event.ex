# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.ArchivedEvent do
  @moduledoc "The archive the host's audit log moves to after the hot window."
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer

  use AshEvents.Chain.Resources,
      {:archive,
       log: AshEvents.Chain.Test.EventLog,
       table: "audit_event_archive",
       repo: AshEvents.Chain.TestRepo}

  multitenancy do
    strategy :attribute
    attribute :organization_id
    global? true
  end
end
