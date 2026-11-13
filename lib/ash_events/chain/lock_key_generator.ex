# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.LockKeyGenerator do
  @moduledoc """
  The advisory-lock key AshEvents takes before it inserts an event, keyed on the chain
  the event will join.

      event_log do
        advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator
      end

  AshEvents takes `pg_advisory_xact_lock` with this key before it inserts the event,
  in the same transaction. A second writer to the same chain therefore waits until
  the first commits, so the chain trigger always reads the true tail and the chain
  stays linear. Writers to other chains do not wait.

  ## Why not the default key

  `AshEvents.AdvisoryLockKeyGenerator.Default` keys on the tenant of the resource
  being written. The chain is partitioned by the log's partition column, which the
  trigger may take from the event's metadata (`:partition_metadata_key`). The two
  disagree for a resource without attribute multitenancy whose events carry a
  partition value in their metadata: the default key is then the shared default
  integer, and two such writes race the tail of a chain that a tenant-scoped write
  holds a different lock for.

  This generator reads the partition the trigger will use: the metadata key when the
  log has one, otherwise the changeset's tenant.

  ## The key

  The key is the one the default generator gives for the same value, so code that
  holds the default key for a tenant (a migration, a backfill) still serializes with
  the log:

    * a UUID is `[hi, lo]`, the first 32 bits of each half, as the default does;
    * an integer is itself;
    * `nil` (the chain with no partition value) is the log's
      `advisory_lock_key_default`;
    * any other string is `[namespace, :erlang.phash2(value)]`.

  `key_for/2` is public, so a host with its own generator (one that scopes keys in
  tests, say) can build on it.
  """

  use AshEvents.AdvisoryLockKeyGenerator

  @namespace 1_394_836_219

  @impl true
  def generate_key!(changeset, default_integer) do
    log = AshEvents.Events.Info.events_event_log!(changeset.resource)

    log
    |> AshEvents.Chain.Info.spec!()
    |> partition_value(changeset)
    |> key_for(default_integer)
  end

  @doc """
  The partition value the chain trigger will set for an event of `changeset`.
  """
  @spec partition_value(map(), Ash.Changeset.t()) :: term()
  def partition_value(%{partition_metadata_key: nil}, changeset), do: changeset.tenant

  def partition_value(%{partition_metadata_key: key}, changeset) do
    metadata = Map.get(changeset.context, :ash_events_metadata, %{})

    value =
      case Map.fetch(metadata, key) do
        {:ok, value} -> value
        :error -> Enum.find_value(metadata, fn {k, v} -> if to_string(k) == key, do: v end)
      end

    if value == "", do: nil, else: value
  end

  @doc "The advisory key for a partition value. See the moduledoc."
  @spec key_for(term(), integer() | [integer()]) :: integer() | [integer()]
  def key_for(nil, default), do: default
  def key_for(value, _default) when is_integer(value), do: value

  def key_for(value, _default) when is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, <<hi::signed-32, _::binary-size(4), lo::signed-32, _::binary-size(4)>>} -> [hi, lo]
      :error -> [@namespace, :erlang.phash2(value, 2_147_483_647)]
    end
  end

  def key_for(value, default), do: key_for(to_string(value), default)
end
