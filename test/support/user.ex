# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.User do
  @moduledoc "The actor a log persists as `user_id`."
  use Ash.Resource,
    domain: AshEvents.Chain.Test.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo AshEvents.Chain.TestRepo
  end

  actions do
    defaults [:read, create: [:name]]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end
end
