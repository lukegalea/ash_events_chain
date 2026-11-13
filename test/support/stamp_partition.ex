# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Test.StampPartition do
  @moduledoc """
  What a host's platform does on every audited write: puts the tenant into the event
  metadata, where the chain trigger takes the partition from.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.tenant do
      nil ->
        changeset

      tenant ->
        Ash.Changeset.set_context(changeset, %{
          ash_events_metadata: %{"organization_id" => tenant}
        })
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
