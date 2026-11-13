# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Extension do
  @moduledoc """
  The Spark extension whose transformer turns an event log into a chained log.

  A host adds it next to `AshEvents.EventLog` and declares the chain with the
  `{:chained_log, opts}` macro:

      use Ash.Resource,
        domain: MyApp.Audit,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

      use AshEvents.Chain.Resources, {:chained_log, partition: :organization_id}

  It has no DSL section of its own. The macro persists the options, and
  `AshEvents.Chain.Transformers.DefineChain` reads them.
  """

  use Spark.Dsl.Extension,
    transformers: [AshEvents.Chain.Transformers.DefineChain]
end
