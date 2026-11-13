# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Resources do
  # credo:disable-for-this-file Credo.Check.Refactor.LongQuoteBlocks
  # The quotes are whole resources, emitted onto the host's own base so the host's
  # policies govern them. A resource-length quote is the point.
  @moduledoc """
  The resource macros a host instantiates on its own resources.

  Each macro goes after the host's own `use` line, so the resource keeps the host's
  base, domain, tenancy and policies. The package emits no policy: who may read the
  log, its archive and the run ledger is the host's decision.

  ## `{:chained_log, opts}`

  On the host's `AshEvents.EventLog` resource, which also lists
  `AshEvents.Chain.Extension`. The host keeps its own `postgres` block (table and
  repo); the extension adds the chain attributes, the chain index and the chain and
  immutability statements to it.

      defmodule MyApp.Audit.EventLog do
        use Ash.Resource,
          domain: MyApp.Audit,
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer],
          extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

        use AshEvents.Chain.Resources,
            {:chained_log,
             partition: :organization_id,
             partition_metadata_key: "organization_id",
             archive_table: "audit_event_archive",
             archive_run: MyApp.Audit.ArchiveRun}

        postgres do
          table "audit_events"
          repo MyApp.Repo
        end

        event_log do
          advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator
        end
      end

  Options:

    * `:partition` - **required**. The column each chain is partitioned by, usually
      the tenant. Events with no value form a chain of their own. The extension adds
      the attribute (`writable?: false`) unless the host declares it.
    * `:partition_type` - the partition attribute's type when the extension adds it.
      Default `:uuid`.
    * `:partition_metadata_key` - the event metadata key the trigger sets the
      partition from, so the column and the metadata cannot disagree. Without it the
      column is written as given.
    * `:digest_columns` - the columns the hash covers, in order. A bare atom renders
      a `NULL` as an empty field; `{column, :omit_nil}` leaves a `NULL` out. The
      default is `[:sequence, :id, :record_id, :version, :occurred_at, :resource,
      :action, :action_type]`, then each `persist_actor_primary_key` column, then the
      partition, `:data`, `:changed_attributes` and `:metadata`, then, when the log
      sets `record_as_of?`, `{:as_of, :omit_nil}` and `{:as_of_range, :omit_nil}`.
      A host whose existing rows were hashed over another list passes that list.
    * `:chain_function`, `:immutable_function` - the trigger functions' names.
      Defaults `"<table>_chain_fn"` and `"<table>_immutable_fn"`. The triggers are
      always `<table>_chain` and `<table>_immutable`.
    * `:archive_table` - the archive's table. With it, the immutability trigger
      allows the one `DELETE` retention makes, and the verifier reads both tables.
    * `:archive_run` - the run ledger resource (`{:archive_run, opts}`). The verifier
      reads purge anchors from it and retention records each step in it.

  ## `{:archive, opts}`

  Where events go after the hot window. Its columns are the log's copied columns
  (`AshEvents.Chain.Info`), with the log's types, plus `archived_at`, so a copied row
  still hashes to its `hash`. An atom column (`resource`, `action`, `action_type`)
  is a string here, so an archived row still loads after the module it names is gone. No create, update or destroy action: rows arrive only
  through `AshEvents.Chain.Retention`, which the database checks against the hot
  row. The guard trigger refuses every `UPDATE` and a `DELETE` of anything younger
  than 400 days.

      defmodule MyApp.Audit.ArchivedEvent do
        use Ash.Resource,
          domain: MyApp.Audit,
          data_layer: AshPostgres.DataLayer,
          authorizers: [Ash.Policy.Authorizer]

        use AshEvents.Chain.Resources,
            {:archive, log: MyApp.Audit.EventLog, table: "audit_event_archive", repo: MyApp.Repo}

        policies do
          # the host's read grant
        end
      end

  Options: `:log`, `:table` and `:repo` (all required), and `:guard_function`, the
  guard function's name (default `"<table>_guard_fn"`). The trigger is
  `<table>_guard`, the statements `<table>_guard_function` and `<table>_guard_trigger`,
  the index `<table>_chain_index`. Actions: `:read` and `:chain` (one chain, in
  sequence order; its argument is the partition column's name).

  ## `{:archive_run, opts}`

  One retention step per row: an archive of a run of rows, or a purge of a run of
  archived rows, with its sequence range, row count, the SHA-256 digest of the rows'
  hashes in order, and whether it verified. A purge also records `tail_hash`, the
  hash of the last purged row, which the verifier starts the remaining chain from.

      defmodule MyApp.Audit.ArchiveRun do
        use MyApp.Platform.Resource, domain: MyApp.Audit

        use AshEvents.Chain.Resources,
            {:archive_run, log: MyApp.Audit.EventLog, table: "audit_archive_runs",
             repo: MyApp.Repo}
      end

  Options: `:log`, `:table` and `:repo` (all required), and `:chain_attribute`, the
  column naming the chain a run belongs to (default `:chain_partition`, with the
  log's partition type). Actions: `:read` and `:record`, the create retention calls.
  Append-only: there is no update or destroy.
  """

  @doc false
  defmacro __using__(which)

  defmacro __using__({:chained_log, opts}) do
    opts = expand(opts, __CALLER__)

    unless Keyword.has_key?(opts, :partition) do
      raise ArgumentError, "{:chained_log, opts} requires :partition"
    end

    extensions = Module.get_attribute(__CALLER__.module, :extensions) || []

    for extension <- [AshEvents.EventLog, AshEvents.Chain.Extension],
        extension not in extensions do
      raise ArgumentError,
            "{:chained_log, opts} needs #{inspect(extension)} in the resource's `extensions:`"
    end

    quote do
      @persist {unquote(AshEvents.Chain.Transformers.DefineChain.opts_key()),
                unquote(Macro.escape(opts))}
    end
  end

  defmacro __using__({:archive, opts}) do
    opts = expand(opts, __CALLER__)
    log = fetch!(opts, :log, :archive)
    table = fetch!(opts, :table, :archive)
    repo = fetch!(opts, :repo, :archive)
    guard_function = Keyword.get(opts, :guard_function, "#{table}_guard_fn")

    check_identifiers!([table, guard_function])

    spec = AshEvents.Chain.Info.spec!(Code.ensure_compiled!(log))
    columns = Enum.map(spec.copied_columns -- [:id], &archive_attribute(log, &1))

    quote location: :keep do
      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          index [unquote(spec.partition), :sequence], name: unquote("#{table}_chain_index")
        end

        custom_statements do
          statement unquote(:"#{table}_guard_function") do
            up unquote(AshEvents.Chain.SQL.archive_guard_function(table, guard_function))
            down unquote(AshEvents.Chain.SQL.drop_function(guard_function))
          end

          statement unquote(:"#{table}_guard_trigger") do
            up unquote(AshEvents.Chain.SQL.archive_guard_trigger(table, guard_function))
            down unquote(AshEvents.Chain.SQL.drop_trigger(table, "#{table}_guard"))
          end
        end
      end

      attributes do
        # The hot row's id, copied rather than generated: a second copy of one event
        # conflicts instead of landing beside it.
        attribute :id, unquote(spec.id_type) do
          primary_key? true
          allow_nil? false
          writable? false
          public? true
          constraints unquote(Macro.escape(spec.id_constraints))
        end

        unquote_splicing(columns)

        attribute :archived_at, :utc_datetime_usec do
          allow_nil? false
          writable? false
          public? true
          description "When retention copied this event out of the hot table."
        end
      end

      actions do
        defaults [:read]
        default_accept []

        read :chain do
          description "One chain's archived events, in sequence order."

          argument unquote(spec.partition), unquote(spec.partition_type) do
            allow_nil? true
            constraints unquote(Macro.escape(spec.partition_constraints))
          end

          prepare {AshEvents.Chain.Preparations.ChainOrder, column: unquote(spec.partition)}
        end
      end

      @persist {:ash_events_chain_archive, %{log: unquote(log)}}
    end
  end

  defmacro __using__({:archive_run, opts}) do
    opts = expand(opts, __CALLER__)
    log = fetch!(opts, :log, :archive_run)
    table = fetch!(opts, :table, :archive_run)
    repo = fetch!(opts, :repo, :archive_run)
    chain_attribute = Keyword.get(opts, :chain_attribute, :chain_partition)

    check_identifiers!([table, chain_attribute])

    spec = AshEvents.Chain.Info.spec!(Code.ensure_compiled!(log))

    quote location: :keep do
      postgres do
        table unquote(table)
        repo unquote(repo)

        custom_indexes do
          index [:store, :kind, unquote(chain_attribute), :to_sequence],
            name: unquote("#{table}_anchor_index")
        end
      end

      actions do
        defaults [:read]

        create :record do
          description "Record one retention step."
          primary? true

          accept [
            :store,
            :kind,
            :status,
            unquote(chain_attribute),
            :from_sequence,
            :to_sequence,
            :row_count,
            :digest,
            :tail_hash,
            :cutoff,
            :reason
          ]
        end
      end

      attributes do
        uuid_primary_key :id

        attribute :store, :atom do
          allow_nil? false
          public? true
          description "The hot table the rows came from."
        end

        attribute :kind, :atom do
          allow_nil? false
          public? true
          constraints one_of: [:archive, :purge]
          description "`archive`: hot table to archive. `purge`: out of the archive."
        end

        attribute :status, :atom do
          allow_nil? false
          public? true
          constraints one_of: [:verified, :failed]
          description "`failed` means the step did not verify and nothing was deleted."
        end

        attribute unquote(chain_attribute), unquote(spec.partition_type) do
          public? true
          constraints unquote(Macro.escape(spec.partition_constraints))
          description "The chain the rows belong to; nil is the chain with no partition value."
        end

        attribute :from_sequence, :integer, public?: true
        attribute :to_sequence, :integer, public?: true

        attribute :row_count, :integer do
          allow_nil? false
          public? true
          constraints min: 0
        end

        attribute :digest, :string do
          public? true
          description "SHA-256 over the rows' hashes, in sequence order."
        end

        attribute :tail_hash, :string do
          public? true

          description "For a purge, the hash of the last purged row: the remaining chain's anchor."
        end

        attribute :cutoff, :utc_datetime_usec do
          allow_nil? false
          public? true
          description "Rows older than this were eligible."
        end

        attribute :reason, :string do
          public? true
          constraints max_length: 500
          description "Why a failed step refused."
        end

        create_timestamp :inserted_at
      end

      @persist {:ash_events_chain_run,
                %{log: unquote(log), chain_attribute: unquote(chain_attribute)}}
    end
  end

  defmacro __using__(other) do
    raise ArgumentError,
          "use AshEvents.Chain.Resources expects {:chained_log, opts}, {:archive, opts} " <>
            "or {:archive_run, opts}, got: #{Macro.to_string(other)}"
  end

  defp expand(opts, caller) do
    Enum.map(opts, fn {key, value} -> {key, Macro.expand(value, caller)} end)
  end

  defp fetch!(opts, key, which) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when not is_nil(value) -> value
      _ -> raise ArgumentError, "{#{inspect(which)}, opts} requires #{inspect(key)}"
    end
  end

  defp check_identifiers!(names) do
    case Enum.reject(names, &AshEvents.Chain.SQL.identifier?/1) do
      [] -> :ok
      bad -> raise ArgumentError, "not plain SQL identifiers: #{inspect(bad)}"
    end
  end

  # An archived column: the log's type and constraints, never generated, never a
  # default. `sequence` is required in the archive: every archived row has one.
  # An atom column (`resource`, `action`, `action_type`) is archived as a string: the
  # same text column, but an archived row still loads after the module or action it
  # names is gone, which over an archive's lifetime it will be.
  defp archive_attribute(log, name) do
    attribute = Ash.Resource.Info.attribute(log, name)
    allow_nil? = name != :sequence and attribute.allow_nil?

    {type, constraints} =
      case attribute.type do
        Ash.Type.Atom -> {:string, [allow_empty?: true, trim?: false]}
        type -> {type, attribute.constraints}
      end

    quote do
      attribute unquote(name), unquote(type) do
        allow_nil? unquote(allow_nil?)
        writable? false
        public? unquote(attribute.public?)
        sensitive? unquote(attribute.sensitive?)
        constraints unquote(Macro.escape(constraints))
      end
    end
  end
end
