# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.ResourcesTest do
  @moduledoc """
  What the macros emit onto the host's resources, and what they refuse.
  """

  use ExUnit.Case, async: true

  alias AshEvents.Chain.{Info, SQL}
  alias AshEvents.Chain.Test.{ArchivedEvent, ArchiveRun, EventLog, LegacyLog}

  describe "{:chained_log, opts}" do
    test "names the statements, triggers and index after the table" do
      assert Enum.map(AshPostgres.DataLayer.Info.custom_statements(EventLog), & &1.name) == [
               :audit_events_chain_function,
               :audit_events_chain_trigger,
               :audit_events_immutable_function,
               :audit_events_immutable_trigger
             ]

      assert ["audit_events_chain_index"] ==
               Enum.map(AshPostgres.DataLayer.Info.custom_indexes(EventLog), & &1.name)

      spec = Info.spec!(EventLog)
      assert spec.chain_function == "audit_events_chain_fn"
      assert spec.immutable_function == "audit_events_immutable_fn"
      assert spec.store == :audit_events

      # A host keeps its existing function names.
      assert Info.spec!(LegacyLog).chain_function == "legacy_audit_chain"
    end

    test "adds the chain attributes, written by the database" do
      for name <- [:sequence, :previous_hash, :hash] do
        attribute = Ash.Resource.Info.attribute(EventLog, name)
        assert attribute.generated? and not attribute.writable?
      end

      refute Ash.Resource.Info.attribute(EventLog, :organization_id).writable?
    end

    test "a trigger statement changes with its function, so both migrate together" do
      spec = Info.spec!(EventLog)
      other = %{spec | digest_columns: tl(spec.digest_columns)}

      assert SQL.chain_function(spec) != SQL.chain_function(other)
      assert SQL.chain_trigger(spec) != SQL.chain_trigger(other)

      for statement <- AshPostgres.DataLayer.Info.custom_statements(EventLog) do
        refute statement.down =~ "CASCADE"
      end
    end

    test "requires a partition" do
      assert_raise ArgumentError, ~r/requires :partition/, fn ->
        defmodule NoPartition do
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

          use AshEvents.Chain.Resources, {:chained_log, []}
        end
      end
    end

    test "requires the extension" do
      assert_raise ArgumentError, ~r/AshEvents.Chain.Extension/, fn ->
        defmodule NoExtension do
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshEvents.EventLog]

          use AshEvents.Chain.Resources, {:chained_log, partition: :organization_id}
        end
      end
    end

    test "refuses a digest column the log does not have" do
      assert_raise Spark.Error.DslError, ~r/does not have/, fn ->
        defmodule MissingColumn do
          use Ash.Resource,
            domain: nil,
            data_layer: AshPostgres.DataLayer,
            extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

          use AshEvents.Chain.Resources,
              {:chained_log, partition: :organization_id, digest_columns: [:id, :nope]}

          postgres do
            table "missing_column_events"
            repo AshEvents.Chain.TestRepo
          end
        end
      end
    end
  end

  describe "{:archive, opts}" do
    test "holds the log's copied columns, with the log's types (atoms as strings), and archived_at" do
      spec = Info.spec!(EventLog)
      names = ArchivedEvent |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      assert Enum.sort(names) == Enum.sort([:archived_at | spec.copied_columns])

      for name <- spec.copied_columns -- [:id] do
        archived = Ash.Resource.Info.attribute(ArchivedEvent, name).type

        case Ash.Resource.Info.attribute(EventLog, name).type do
          Ash.Type.Atom -> assert archived == Ash.Type.String
          type -> assert archived == type
        end
      end

      assert [:id] == Ash.Resource.Info.primary_key(ArchivedEvent)
      refute Ash.Resource.Info.attribute(ArchivedEvent, :sequence).allow_nil?
    end

    test "has no write action" do
      types = ArchivedEvent |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.uniq()
      assert types == [:read]
    end

    test "names its guard after the table" do
      assert Enum.map(AshPostgres.DataLayer.Info.custom_statements(ArchivedEvent), & &1.name) == [
               :audit_event_archive_guard_function,
               :audit_event_archive_guard_trigger
             ]
    end
  end

  describe "{:archive_run, opts}" do
    test "is append-only, with the chain column typed as the partition" do
      types = ArchiveRun |> Ash.Resource.Info.actions() |> Enum.map(& &1.type) |> Enum.sort()
      assert types == [:create, :read]

      assert Ash.Resource.Info.attribute(ArchiveRun, :chain_organization_id).type ==
               Ash.Resource.Info.attribute(EventLog, :organization_id).type

      assert ["audit_archive_runs_anchor_index"] ==
               Enum.map(AshPostgres.DataLayer.Info.custom_indexes(ArchiveRun), & &1.name)
    end
  end
end
