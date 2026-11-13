# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Info do
  @moduledoc """
  Reads a chained log's spec: what `AshEvents.Chain.Transformers.DefineChain` resolved
  from the `{:chained_log, opts}` declaration and persisted on the resource.

  The spec is a map:

    * `:log`, `:table`, `:repo` - the event log resource, its table and repo.
    * `:store` - the table name as an atom; the run ledger's `store` for this log.
    * `:partition`, `:partition_type`, `:partition_constraints`, `:partition_sql_type` -
      the column each chain is partitioned by, and its type.
    * `:partition_metadata_key` - the metadata key the trigger takes the partition
      from, or `nil` when the column is written as given.
    * `:digest_columns` - `[{column, :empty_if_nil | :omit_nil}]`, in digest order.
    * `:copied_columns` - every column the archive holds: the id, the sequence, the
      partition, the digest columns, `previous_hash` and `hash`.
    * `:id_type`, `:id_constraints` - the log's primary key type.
    * `:chain_function`, `:immutable_function` - the trigger functions' names.
    * `:archive_table`, `:archive_run` - the archive table and the run ledger
      resource, or `nil`.
  """

  @persist_key :ash_events_chain

  @doc false
  def persist_key, do: @persist_key

  @doc "The chain spec of `log`, or `nil` when it is not a chained log."
  @spec spec(module()) :: map() | nil
  def spec(log), do: Spark.Dsl.Extension.get_persisted(log, @persist_key)

  @doc "The chain spec of `log`. Raises when it is not a chained log."
  @spec spec!(module()) :: map()
  def spec!(log) do
    spec(log) ||
      raise ArgumentError,
            "#{inspect(log)} is not a chained log: it needs " <>
              "`use AshEvents.Chain.Resources, {:chained_log, ...}` and the " <>
              "AshEvents.Chain.Extension extension"
  end

  @doc "Whether `log` is a chained log."
  @spec chained?(module()) :: boolean()
  def chained?(log), do: not is_nil(spec(log))

  @doc """
  Dumps a partition value to what Postgrex binds for the partition's SQL type.
  `nil` stays `nil`.
  """
  @spec dump_partition(map(), term()) :: term()
  def dump_partition(_spec, nil), do: nil

  def dump_partition(spec, value) do
    {:ok, cast} = Ash.Type.cast_input(spec.partition_type, value, spec.partition_constraints)
    {:ok, dumped} = Ash.Type.dump_to_native(spec.partition_type, cast, spec.partition_constraints)
    dumped
  end

  @doc "Loads a partition value read by a raw query."
  @spec load_partition(map(), term()) :: term()
  def load_partition(_spec, nil), do: nil

  def load_partition(spec, raw) do
    {:ok, value} = Ash.Type.cast_stored(spec.partition_type, raw, spec.partition_constraints)
    value
  end

  @doc "Loads a primary key read by a raw query."
  @spec load_id(map(), term()) :: term()
  def load_id(spec, raw) do
    {:ok, value} = Ash.Type.cast_stored(spec.id_type, raw, spec.id_constraints)
    value
  end
end
