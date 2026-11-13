# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias AshEvents.Chain.TestRepo

  using do
    quote do
      alias AshEvents.Chain.TestRepo
      import AshEvents.Chain.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc "Runs `fun` with `trigger` on `table` disabled: what an operator does before a quiet edit."
  def without_trigger(table, trigger, fun) do
    TestRepo.query!("ALTER TABLE #{table} DISABLE TRIGGER #{trigger}")
    fun.()
  after
    TestRepo.query!("ALTER TABLE #{table} ENABLE TRIGGER #{trigger}")
  end

  def dump(uuid), do: Ecto.UUID.dump!(uuid)
end
