# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Transformers.DefineChain do
  @moduledoc """
  Builds the chain onto an event log from the `{:chained_log, opts}` macro's persisted
  options:

    * the `sequence`, `previous_hash` and `hash` attributes, and the partition
      attribute, each only when the host has not declared it;
    * the chain index, `<table>_chain_index` on `(partition, sequence)`;
    * four custom statements: `<table>_chain_function`, `<table>_chain_trigger`,
      `<table>_immutable_function` and `<table>_immutable_trigger`;
    * the resolved spec (`AshEvents.Chain.Info`), persisted on the resource.

  Runs after AshEvents adds the log's own attributes, so the digest columns can be
  checked against the attributes the table will have.
  """

  use Spark.Dsl.Transformer

  alias AshEvents.Chain.SQL
  alias Spark.Dsl.Transformer

  @opts_key :ash_events_chain_opts

  @doc false
  def opts_key, do: @opts_key

  @impl true
  def before?(AshEvents.EventLog.Transformers.AddAttributes), do: false
  def before?(_), do: true

  @impl true
  def after?(AshEvents.EventLog.Transformers.AddAttributes), do: true
  def after?(_), do: false

  @impl true
  def transform(dsl) do
    case Transformer.get_persisted(dsl, @opts_key) do
      nil -> {:ok, dsl}
      opts -> build(dsl, opts)
    end
  end

  defp build(dsl, opts) do
    module = Transformer.get_persisted(dsl, :module)

    with {:ok, table} <- table(dsl, module),
         :ok <- refuse_cloaked(dsl, module),
         {:ok, dsl} <- add_chain_attributes(dsl, opts),
         {:ok, spec} <- spec(dsl, module, table, opts),
         {:ok, dsl} <- add_index(dsl, module, spec),
         {:ok, dsl} <- add_statements(dsl, module, spec) do
      {:ok, Transformer.persist(dsl, AshEvents.Chain.Info.persist_key(), spec)}
    end
  end

  defp table(dsl, module) do
    case Transformer.get_option(dsl, [:postgres], :table) do
      table when is_binary(table) ->
        if SQL.identifier?(table),
          do: {:ok, table},
          else: error(module, [:postgres, :table], "#{inspect(table)} is not a plain identifier")

      _ ->
        error(module, [:postgres, :table], "a chained log needs a postgres table")
    end
  end

  # The digest covers the plaintext columns. An encrypted log stores ciphertext there
  # instead, and its metadata cannot be read by the trigger.
  defp refuse_cloaked(dsl, module) do
    if Transformer.get_option(dsl, [:event_log], :cloak_vault) do
      error(
        module,
        [:event_log, :cloak_vault],
        "a chained log cannot be encrypted with cloak_vault"
      )
    else
      :ok
    end
  end

  defp add_chain_attributes(dsl, opts) do
    partition = Keyword.fetch!(opts, :partition)
    partition_type = Keyword.get(opts, :partition_type, :uuid)

    with {:ok, dsl} <-
           Ash.Resource.Builder.add_new_attribute(dsl, :sequence, :integer,
             generated?: true,
             writable?: false,
             public?: false,
             description: "Insert position. Orders the hash chain."
           ),
         {:ok, dsl} <-
           Ash.Resource.Builder.add_new_attribute(dsl, partition, partition_type,
             writable?: false,
             public?: false,
             description: "The chain this event belongs to. NULL events form their own chain."
           ),
         {:ok, dsl} <-
           Ash.Resource.Builder.add_new_attribute(dsl, :previous_hash, :string,
             generated?: true,
             writable?: false,
             public?: false,
             description: "The hash of the preceding event in this event's chain."
           ) do
      Ash.Resource.Builder.add_new_attribute(dsl, :hash, :string,
        generated?: true,
        writable?: false,
        public?: false,
        description: "SHA-256 over this event's digest columns and `previous_hash`."
      )
    end
  end

  defp spec(dsl, module, table, opts) do
    partition = Keyword.fetch!(opts, :partition)
    attributes = Transformer.get_entities(dsl, [:attributes])
    attribute = fn name -> Enum.find(attributes, &(&1.name == name)) end

    digest_columns =
      opts
      |> Keyword.get(:digest_columns)
      |> Kernel.||(default_digest_columns(dsl, partition))
      |> SQL.normalize_digest_columns()

    copied_columns =
      Enum.uniq(
        [:id, :sequence, partition] ++
          Enum.map(digest_columns, &elem(&1, 0)) ++ [:previous_hash, :hash]
      )

    partition_attribute = attribute.(partition)
    id_attribute = attribute.(:id)

    function = fn key, suffix -> Keyword.get(opts, key) || "#{table}_#{suffix}" end

    spec = %{
      log: module,
      table: table,
      store: String.to_atom(table),
      partition: partition,
      partition_type: partition_attribute.type,
      partition_constraints: partition_attribute.constraints,
      partition_sql_type: sql_type(partition_attribute.type),
      partition_metadata_key: Keyword.get(opts, :partition_metadata_key),
      digest_columns: digest_columns,
      copied_columns: copied_columns,
      id_type: id_attribute.type,
      id_constraints: id_attribute.constraints,
      chain_function: function.(:chain_function, "chain_fn"),
      immutable_function: function.(:immutable_function, "immutable_fn"),
      archive_table: Keyword.get(opts, :archive_table),
      archive_run: Keyword.get(opts, :archive_run)
    }

    with :ok <- check_columns(module, copied_columns, attribute),
         :ok <- check_identifiers(module, spec) do
      check_metadata_key(module, spec)
    end
  rescue
    error in ArgumentError -> error(Transformer.get_persisted(dsl, :module), [], error.message)
  end

  # The canonical form: every column ash_events writes, the actor columns, the
  # partition and, with `record_as_of?`, the application time. A `NULL` actor or
  # partition is an empty field; a `NULL` `as_of` or `as_of_range` is left out, so a
  # row without either hashes as it did before they existed.
  defp default_digest_columns(dsl, partition) do
    actors =
      dsl
      |> Transformer.get_entities([:event_log])
      |> Enum.filter(&is_struct(&1, AshEvents.EventLog.PersistActorPrimaryKey))
      |> Enum.map(& &1.name)

    as_of =
      if Transformer.get_option(dsl, [:event_log], :record_as_of?, false),
        do: [{:as_of, :omit_nil}, {:as_of_range, :omit_nil}],
        else: []

    [:sequence, :id, :record_id, :version, :occurred_at, :resource, :action, :action_type] ++
      actors ++ [partition, :data, :changed_attributes, :metadata] ++ as_of
  end

  defp sql_type(type) do
    case Ash.Type.get_type(type) do
      Ash.Type.UUID -> "uuid"
      Ash.Type.UUIDv7 -> "uuid"
      Ash.Type.Integer -> "bigint"
      Ash.Type.String -> "text"
      Ash.Type.Atom -> "text"
      other -> raise ArgumentError, "a chain cannot be partitioned by a #{inspect(other)}"
    end
  end

  defp check_columns(module, columns, attribute) do
    case Enum.reject(columns, attribute) do
      [] ->
        :ok

      missing ->
        error(module, [], "the chain names columns the log does not have: #{inspect(missing)}")
    end
  end

  defp check_identifiers(module, spec) do
    names =
      [spec.chain_function, spec.immutable_function | spec.copied_columns] ++
        Enum.reject([spec.archive_table], &is_nil/1)

    case Enum.reject(names, &SQL.identifier?/1) do
      [] -> :ok
      bad -> error(module, [], "not plain SQL identifiers: #{inspect(bad)}")
    end
  end

  defp check_metadata_key(module, %{partition_metadata_key: key} = spec) do
    if is_nil(key) or (is_binary(key) and key =~ ~r/^[A-Za-z0-9_]+$/) do
      {:ok, spec}
    else
      error(module, [], "partition_metadata_key must be a string of letters, digits and _")
    end
  end

  defp add_index(dsl, module, spec) do
    name = "#{spec.table}_chain_index"
    existing = Transformer.get_entities(dsl, [:postgres, :custom_indexes])

    if Enum.any?(existing, &(&1.name == name)) do
      error(
        module,
        [:postgres, :custom_indexes],
        "#{name} is the chain's index; remove the host's"
      )
    else
      {:ok, index} =
        Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_indexes], :index,
          fields: [spec.partition, :sequence],
          name: name
        )

      {:ok, Transformer.add_entity(dsl, [:postgres, :custom_indexes], index, type: :append)}
    end
  end

  defp add_statements(dsl, module, spec) do
    table = spec.table

    statements = [
      {:"#{table}_chain_function", SQL.chain_function(spec),
       SQL.drop_function(spec.chain_function)},
      {:"#{table}_chain_trigger", SQL.chain_trigger(spec),
       SQL.drop_trigger(table, "#{table}_chain")},
      {:"#{table}_immutable_function", SQL.immutable_function(spec),
       SQL.drop_function(spec.immutable_function)},
      {:"#{table}_immutable_trigger", SQL.immutable_trigger(spec),
       SQL.drop_trigger(table, "#{table}_immutable")}
    ]

    existing =
      dsl |> Transformer.get_entities([:postgres, :custom_statements]) |> MapSet.new(& &1.name)

    case Enum.filter(statements, fn {name, _, _} -> name in existing end) do
      [] ->
        {:ok, Enum.reduce(statements, dsl, &add_statement/2)}

      clashes ->
        names = Enum.map(clashes, &elem(&1, 0))
        error(module, [:postgres, :custom_statements], "the chain owns #{inspect(names)}")
    end
  end

  defp add_statement({name, up, down}, dsl) do
    {:ok, statement} =
      Transformer.build_entity(AshPostgres.DataLayer, [:postgres, :custom_statements], :statement,
        name: name,
        up: up,
        down: down
      )

    Transformer.add_entity(dsl, [:postgres, :custom_statements], statement, type: :append)
  end

  defp error(module, path, message) do
    {:error, Spark.Error.DslError.exception(module: module, path: path, message: message)}
  end
end
