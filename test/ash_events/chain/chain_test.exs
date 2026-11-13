# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.ChainTest do
  @moduledoc """
  Tamper-evidence, tested by tampering: the trigger refuses an edit, and the chain
  finds the edit made with the trigger disabled.
  """

  use AshEvents.Chain.DataCase, async: false

  require Ash.Query

  alias AshEvents.Chain
  alias AshEvents.Chain.Test.{EventLog, Note}

  setup do
    %{org: Ash.UUID.generate()}
  end

  defp note!(org, body \\ "x") do
    Note
    |> Ash.Changeset.for_create(:create, %{body: body}, tenant: org)
    |> Ash.create!()
  end

  defp events(org) do
    TestRepo.query!(
      "SELECT sequence, hash, previous_hash, organization_id FROM audit_events " <>
        "WHERE organization_id = $1::uuid ORDER BY sequence",
      [dump(org)]
    ).rows
  end

  # An event written straight to the table, so the chain trigger is all that runs.
  defp insert_event!(org) do
    metadata = if org, do: %{"organization_id" => org}, else: %{}

    [[id]] =
      TestRepo.query!(
        "INSERT INTO audit_events (record_id, metadata, occurred_at, resource, action, action_type) " <>
          "VALUES (gen_random_uuid(), $1::jsonb, now(), 'Elixir.Probe', 'create', 'create') RETURNING id",
        [metadata]
      ).rows

    id
  end

  describe "the chain as written" do
    test "every event carries a hash, and the partition taken from its metadata", ctx do
      note = note!(ctx.org)

      assert [[_seq, hash, previous, org]] = events(ctx.org)
      assert is_binary(hash) and byte_size(hash) == 64
      assert is_nil(previous)
      assert Ecto.UUID.cast!(org) == ctx.org

      [event] =
        EventLog
        |> Ash.Query.filter(record_id == ^note.id)
        |> Ash.read!(authorize?: false)

      assert event.metadata["organization_id"] == ctx.org
      assert event.organization_id == ctx.org
    end

    test "each event links to the one before it", ctx do
      note = note!(ctx.org, "one")
      note |> Ash.Changeset.for_update(:update, %{body: "two"}) |> Ash.update!()
      note!(ctx.org, "three")

      rows = events(ctx.org)
      hashes = Enum.map(rows, fn [_, hash, _, _] -> hash end)
      previouses = Enum.map(rows, fn [_, _, previous, _] -> previous end)

      assert length(rows) == 3
      assert previouses == [nil | Enum.take(hashes, 2)]
      assert Enum.uniq(hashes) == hashes
    end

    test "chains are per partition, so one tenant's writes do not enter another's", ctx do
      other = Ash.UUID.generate()

      note!(ctx.org)
      note!(other)
      note!(ctx.org)

      [[_, first_hash, _, _], [_, _, second_previous, _]] = events(ctx.org)
      assert second_previous == first_hash

      assert [[_, _, nil, _]] = events(other)
    end

    test "events with no partition value form a chain of their own" do
      first = insert_event!(nil)
      second = insert_event!(nil)

      [[first_hash]] =
        TestRepo.query!("SELECT hash FROM audit_events WHERE id = $1", [first]).rows

      assert [[^first_hash, nil]] =
               TestRepo.query!(
                 "SELECT previous_hash, organization_id FROM audit_events WHERE id = $1",
                 [second]
               ).rows

      assert %{partition: nil, findings: [], checked: checked} = Chain.verify(EventLog, nil)
      assert checked >= 2
    end

    # The canonical form two existing hosts already write: a row hashed by this package
    # must hash to what their triggers computed for the same row, or their existing
    # chains stop verifying on adoption. Written out here by hand, not built from
    # `AshEvents.Chain.SQL`.
    test "the hash is the established canonical form", ctx do
      note!(ctx.org)

      assert [[true]] =
               TestRepo.query!(
                 """
                 SELECT hash = encode(sha256(convert_to(concat_ws('|',
                   coalesce(previous_hash, ''),
                   sequence::text, id::text, record_id::text, version::text,
                   occurred_at::text, resource, action, action_type,
                   coalesce(user_id::text, ''), coalesce(organization_id::text, ''),
                   data::text, changed_attributes::text, metadata::text
                 ), 'UTF8')), 'hex')
                 FROM audit_events WHERE organization_id = $1::uuid
                 """,
                 [dump(ctx.org)]
               ).rows
    end

    test "verify/2 passes on a chain nobody has touched", ctx do
      note!(ctx.org)
      note!(ctx.org)

      assert %{partition: partition, findings: [], checked: 2, anchored_after: nil} =
               Chain.verify(EventLog, ctx.org)

      assert partition == ctx.org
    end

    test "verify_all/1 verifies every chain", ctx do
      other = Ash.UUID.generate()
      note!(ctx.org)
      note!(other)

      results = Chain.verify_all(EventLog)
      partitions = Enum.map(results, & &1.partition)

      assert ctx.org in partitions and other in partitions
      assert Chain.clean?(results)
    end

    # The trigger runs on every audited write, so a tail lookup that scans the table
    # makes each write cost as much as the whole log. A log large enough that the
    # planner prefers the index, then one write per branch of the lookup.
    test "the tail lookup reads the index, for a partition and for none", ctx do
      without_trigger("audit_events", "audit_events_chain", fn ->
        TestRepo.query!(
          "INSERT INTO audit_events (record_id, occurred_at, resource, action, action_type, organization_id) " <>
            "SELECT gen_random_uuid(), now(), 'Elixir.Filler', 'create', 'create', " <>
            "CASE WHEN g % 4 = 0 THEN NULL ELSE $1::uuid END FROM generate_series(1, 20000) g",
          [dump(ctx.org)]
        )
      end)

      TestRepo.query!("ANALYZE audit_events")
      before = scans()

      insert_event!(ctx.org)
      insert_event!(nil)

      after_writes = scans()
      assert after_writes.seq == before.seq
      assert after_writes.index >= before.index + 2
    end
  end

  describe "the trigger prevents" do
    test "UPDATE", ctx do
      note!(ctx.org)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        TestRepo.query!(
          "UPDATE audit_events SET action = 'tampered' WHERE organization_id = $1::uuid",
          [dump(ctx.org)]
        )
      end
    end

    test "DELETE", ctx do
      note!(ctx.org)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        TestRepo.query!("DELETE FROM audit_events WHERE organization_id = $1::uuid", [
          dump(ctx.org)
        ])
      end
    end
  end

  describe "the chain detects what the trigger could not prevent" do
    test "an altered row", ctx do
      for body <- ~w(one two three), do: note!(ctx.org, body)

      without_trigger("audit_events", "audit_events_immutable", fn ->
        TestRepo.query!(
          "UPDATE audit_events SET action = 'quietly_changed' WHERE organization_id = $1::uuid " <>
            "AND sequence = (SELECT min(sequence) FROM audit_events WHERE organization_id = $1::uuid)",
          [dump(ctx.org)]
        )
      end)

      assert %{findings: [finding]} = Chain.verify(EventLog, ctx.org)
      assert finding.problem == :altered
      assert %DateTime{} = finding.occurred_at
      assert is_binary(finding.id)
    end

    test "a removed row, by the gap it leaves", ctx do
      for body <- ~w(one two three), do: note!(ctx.org, body)

      without_trigger("audit_events", "audit_events_immutable", fn ->
        TestRepo.query!(
          "DELETE FROM audit_events WHERE organization_id = $1::uuid AND sequence = " <>
            "(SELECT min(sequence) + 1 FROM audit_events WHERE organization_id = $1::uuid)",
          [dump(ctx.org)]
        )
      end)

      assert %{findings: findings} = Chain.verify(EventLog, ctx.org)
      assert Enum.any?(findings, &(&1.problem == :broken_link))
    end

    test "an event forged with the chain trigger disabled", ctx do
      note!(ctx.org)
      note!(ctx.org)

      without_trigger("audit_events", "audit_events_chain", fn ->
        TestRepo.query!(
          """
          INSERT INTO audit_events
            (record_id, version, metadata, data, changed_attributes,
             occurred_at, resource, action, action_type, organization_id)
          VALUES
            (gen_random_uuid(), 1, $1::jsonb, '{}'::jsonb, '{}'::jsonb,
             now(), 'Elixir.Forged', 'approve', 'create', $2::uuid)
          """,
          [%{"organization_id" => ctx.org}, dump(ctx.org)]
        )
      end)

      assert %{findings: [%{problem: :unchained}], checked: 3} = Chain.verify(EventLog, ctx.org)
    end

    test "rows written before the chain existed are skipped, not reported", ctx do
      without_trigger("audit_events", "audit_events_chain", fn ->
        for _ <- 1..2 do
          TestRepo.query!(
            "INSERT INTO audit_events (record_id, occurred_at, resource, action, action_type, organization_id) " <>
              "VALUES (gen_random_uuid(), now(), 'Elixir.Old', 'create', 'create', $1::uuid)",
            [dump(ctx.org)]
          )
        end
      end)

      note!(ctx.org)

      assert %{findings: [], checked: 1, skipped_unchained_prefix: 2} =
               Chain.verify(EventLog, ctx.org)
    end
  end

  # This transaction's scans of audit_events and of the chain index.
  defp scans do
    [[seq, index]] =
      TestRepo.query!("""
      SELECT seq_scan, pg_stat_get_xact_numscans('audit_events_chain_index'::regclass)
      FROM pg_stat_xact_user_tables
      WHERE relid = 'audit_events'::regclass
      """).rows

    %{seq: seq, index: index}
  end
end
