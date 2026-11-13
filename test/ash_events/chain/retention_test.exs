# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.RetentionTest do
  @moduledoc """
  Ninety days hot, archived with a verified copy, never purged before four hundred
  days. The refusals first: what the database will not delete, what a failed
  verification leaves in place, what a purge never reaches. Then the moves that do
  happen, and the chain verifying across hot, archived and purged rows.
  """

  use AshEvents.Chain.DataCase, async: false

  alias AshEvents.Chain
  alias AshEvents.Chain.Retention
  alias AshEvents.Chain.Test.{Actors, ArchivedEvent, ArchiveRun, EventLog, RetentionWorker}

  setup do
    %{org: Ash.UUID.generate(), as: [actor: Actors.retention()]}
  end

  # An event in `org`'s chain, `days_ago` old, naming a module that no longer exists.
  # The chain trigger hashes and links it.
  defp event!(org, days_ago) do
    [[id]] =
      TestRepo.query!(
        "INSERT INTO audit_events (record_id, metadata, occurred_at, resource, action, action_type) " <>
          "VALUES (gen_random_uuid(), $1::jsonb, now() - make_interval(days => $2), " <>
          "'Elixir.MyApp.Gone', 'create', 'create') RETURNING id",
        [%{"organization_id" => org}, days_ago]
      ).rows

    Ecto.UUID.cast!(id)
  end

  defp hot_count(org), do: count("audit_events", org)
  defp archived_count(org), do: count("audit_event_archive", org)

  defp count(table, org) do
    [[n]] =
      TestRepo.query!("SELECT count(*) FROM #{table} WHERE organization_id = $1::uuid", [
        dump(org)
      ]).rows

    n
  end

  # Copies one hot row to the archive as it is, optionally with `data` changed.
  defp plant_copy!(id, data \\ nil) do
    TestRepo.query!(
      """
      INSERT INTO audit_event_archive
        (id, sequence, organization_id, record_id, version, occurred_at, resource, action,
         action_type, user_id, data, changed_attributes, metadata, previous_hash, hash,
         archived_at)
      SELECT id, sequence, organization_id, record_id, version, occurred_at, resource, action,
             action_type, user_id, coalesce($2::jsonb, data), changed_attributes, metadata,
             previous_hash, hash, now()
      FROM audit_events WHERE id = $1::uuid
      """,
      [dump(id), data]
    )
  end

  defp step_for(steps, org) do
    Enum.find(steps, fn
      {_, %ArchiveRun{chain_organization_id: ^org}} -> true
      _ -> false
    end) || :nothing
  end

  describe "the hot table refuses a delete" do
    test "of a row with no archived copy", ctx do
      id = event!(ctx.org, 120)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        TestRepo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [dump(id)])
      end
    end

    test "of a row whose archived copy differs from it", ctx do
      id = event!(ctx.org, 120)
      plant_copy!(id, %{"tampered" => true})

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        TestRepo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [dump(id)])
      end
    end

    test "of a row younger than ninety days, even with an identical copy", ctx do
      id = event!(ctx.org, 89)
      plant_copy!(id)

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        TestRepo.query!("DELETE FROM audit_events WHERE id = $1::uuid", [dump(id)])
      end
    end
  end

  describe "archive refuses" do
    test "a hot window under ninety days, and moves nothing", ctx do
      event!(ctx.org, 200)
      event!(ctx.org, 1)

      assert {:error, {:below_floor, :hot_days, 90}} =
               Retention.archive(EventLog, [hot_days: 89] ++ ctx.as)

      assert hot_count(ctx.org) == 2
      assert archived_count(ctx.org) == 0
    end

    test "a copy that differs from the hot row, and deletes nothing", ctx do
      [first | _] = for days <- [200, 150, 120], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      # A copy already in the archive that differs from the hot row. The verifier sees
      # two different rows at one position first; the copy comparison would refuse it
      # too. Either way the move stops before any delete.
      plant_copy!(first, %{"tampered" => true})

      {:ok, steps} = Retention.archive(EventLog, ctx.as)

      assert {:failed, %ArchiveRun{status: :failed, reason: reason, kind: :archive}} =
               step_for(steps, ctx.org)

      assert reason =~ ~r/finding|differ/
      assert hot_count(ctx.org) == 4
      assert archived_count(ctx.org) == 1
    end

    test "a chain with a verification finding, and moves nothing", ctx do
      for days <- [200, 150], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      without_trigger("audit_events", "audit_events_immutable", fn ->
        TestRepo.query!(
          "UPDATE audit_events SET action = 'quietly_changed' WHERE organization_id = $1::uuid " <>
            "AND sequence = (SELECT min(sequence) FROM audit_events WHERE organization_id = $1::uuid)",
          [dump(ctx.org)]
        )
      end)

      {:ok, steps} = Retention.archive(EventLog, ctx.as)

      assert {:failed, %ArchiveRun{reason: reason, row_count: 0}} = step_for(steps, ctx.org)
      assert reason =~ "finding"
      assert hot_count(ctx.org) == 3
      assert archived_count(ctx.org) == 0
    end

    test "to record a step without an actor the host's policy allows", ctx do
      for days <- [200, 150], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      assert_raise Ash.Error.Forbidden, fn -> Retention.archive(EventLog) end

      # The move's transaction rolled back with the refused record.
      assert hot_count(ctx.org) == 3
      assert archived_count(ctx.org) == 0
    end
  end

  describe "archive moves" do
    test "the old run of a chain, verified, and the chain verifies across both tables", ctx do
      for days <- [200, 150, 120], do: event!(ctx.org, days)
      for days <- [30, 1], do: event!(ctx.org, days)

      {:ok, steps} = Retention.archive(EventLog, ctx.as)

      assert {:archived, %ArchiveRun{} = run} = step_for(steps, ctx.org)
      assert run.status == :verified
      assert run.store == :audit_events
      assert run.row_count == 3
      assert run.to_sequence - run.from_sequence == 2
      assert is_binary(run.digest) and byte_size(run.digest) == 64

      assert hot_count(ctx.org) == 2
      assert archived_count(ctx.org) == 3
      assert %{findings: [], checked: 5} = Chain.verify(EventLog, ctx.org)

      archived =
        ArchivedEvent
        |> Ash.Query.for_read(:chain, %{organization_id: ctx.org})
        |> Ash.read!()

      assert length(archived) == 3
      assert Enum.map(archived, & &1.sequence) == Enum.sort(Enum.map(archived, & &1.sequence))

      # The events name a module that does not exist; archived, they still load.
      assert Enum.all?(archived, &(&1.resource == "Elixir.MyApp.Gone"))
    end

    test "never the tail of a chain, so the next event still links to it", ctx do
      for days <- [300, 200, 100], do: event!(ctx.org, days)

      {:ok, steps} = Retention.archive(EventLog, ctx.as)
      assert {:archived, %ArchiveRun{row_count: 2}} = step_for(steps, ctx.org)
      assert hot_count(ctx.org) == 1

      event!(ctx.org, 0)
      assert %{findings: [], checked: 4} = Chain.verify(EventLog, ctx.org)
    end

    test "nothing on a second run", ctx do
      for days <- [200, 1], do: event!(ctx.org, days)

      {:ok, _} = Retention.archive(EventLog, ctx.as)
      {:ok, again} = Retention.archive(EventLog, ctx.as)

      assert step_for(again, ctx.org) == :nothing
    end

    # A move retried after an earlier copy landed: the copy skips rows already in the
    # archive, the comparison checks the rows that are there, and the move completes
    # with one archived row per event.
    test "again after its copy already landed", ctx do
      ids = for days <- [200, 150, 120], do: event!(ctx.org, days)
      event!(ctx.org, 1)
      Enum.each(Enum.take(ids, 2), &plant_copy!/1)

      {:ok, steps} = Retention.archive(EventLog, ctx.as)

      assert {:archived, %ArchiveRun{status: :verified, row_count: 3}} = step_for(steps, ctx.org)
      assert archived_count(ctx.org) == 3
      assert hot_count(ctx.org) == 1
      assert %{findings: [], checked: 4} = Chain.verify(EventLog, ctx.org)
    end

    test "nothing younger than the hot window", ctx do
      for days <- [80, 40, 1], do: event!(ctx.org, days)

      {:ok, steps} = Retention.archive(EventLog, ctx.as)

      assert step_for(steps, ctx.org) == :nothing
      assert hot_count(ctx.org) == 3
    end

    test "at most a batch at a time", ctx do
      for days <- [300, 250, 200, 150], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      {:ok, steps} = Retention.archive(EventLog, [batch_size: 3] ++ ctx.as)
      assert {:archived, %ArchiveRun{row_count: 3}} = step_for(steps, ctx.org)

      {:ok, steps} = Retention.archive(EventLog, [batch_size: 3] ++ ctx.as)
      assert {:archived, %ArchiveRun{row_count: 1}} = step_for(steps, ctx.org)

      assert %{findings: [], checked: 5} = Chain.verify(EventLog, ctx.org)
    end
  end

  describe "the verifier reads the archive" do
    setup ctx do
      for days <- [200, 150, 120], do: event!(ctx.org, days)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive(EventLog, ctx.as)
      :ok
    end

    test "and finds an archived row altered", ctx do
      without_trigger("audit_event_archive", "audit_event_archive_guard", fn ->
        TestRepo.query!(
          "UPDATE audit_event_archive SET data = '{\"quietly\": true}' WHERE organization_id = $1::uuid " <>
            "AND sequence = (SELECT min(sequence) + 1 FROM audit_event_archive WHERE organization_id = $1::uuid)",
          [dump(ctx.org)]
        )
      end)

      assert %{findings: [%{problem: :altered}]} = Chain.verify(EventLog, ctx.org)
    end

    test "and finds an archived row removed", ctx do
      without_trigger("audit_event_archive", "audit_event_archive_guard", fn ->
        TestRepo.query!(
          "DELETE FROM audit_event_archive WHERE organization_id = $1::uuid " <>
            "AND sequence = (SELECT min(sequence) + 1 FROM audit_event_archive WHERE organization_id = $1::uuid)",
          [dump(ctx.org)]
        )
      end)

      assert %{findings: findings} = Chain.verify(EventLog, ctx.org)
      assert Enum.any?(findings, &(&1.problem == :broken_link))
    end
  end

  describe "purge" do
    test "never runs unless an age is given", ctx do
      assert {:ok, :disabled} = Retention.purge(EventLog, ctx.as)
    end

    test "refuses fewer than four hundred days, and deletes nothing", ctx do
      for days <- [500, 450], do: event!(ctx.org, days)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive(EventLog, ctx.as)

      assert {:error, {:below_floor, :purge_after_days, 400}} =
               Retention.purge(EventLog, [purge_after_days: 399] ++ ctx.as)

      assert archived_count(ctx.org) == 2
    end

    test "a 399-day row is never purged, and what remains verifies from the anchor", ctx do
      for days <- [401, 399], do: event!(ctx.org, days)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive(EventLog, ctx.as)
      assert archived_count(ctx.org) == 2

      {:ok, steps} = Retention.purge(EventLog, [purge_after_days: 400] ++ ctx.as)

      assert {:purged, %ArchiveRun{kind: :purge, row_count: 1, tail_hash: tail, to_sequence: to}} =
               step_for(steps, ctx.org)

      assert is_binary(tail)
      assert archived_count(ctx.org) == 1

      # The database refuses the younger row whoever asks.
      assert_raise Postgrex.Error, ~r/400 days/, fn ->
        TestRepo.query!("DELETE FROM audit_event_archive WHERE organization_id = $1::uuid", [
          dump(ctx.org)
        ])
      end

      assert %{findings: [], checked: 2, anchored_after: ^to} = Chain.verify(EventLog, ctx.org)
    end

    test "the archive refuses every update", ctx do
      event!(ctx.org, 500)
      event!(ctx.org, 1)
      {:ok, _} = Retention.archive(EventLog, ctx.as)

      assert_raise Postgrex.Error, ~r/400 days/, fn ->
        TestRepo.query!(
          "UPDATE audit_event_archive SET action = 'x' WHERE organization_id = $1::uuid",
          [dump(ctx.org)]
        )
      end
    end
  end

  describe "the worker" do
    test "archives, then purges with the configured options, as the configured actor", ctx do
      for days <- [200, 150], do: event!(ctx.org, days)
      event!(ctx.org, 1)

      assert RetentionWorker.retention_opts()[:batch_size] == 500

      assert {:ok, %{archived: archived, purged: :disabled}} =
               RetentionWorker.perform(%Oban.Job{args: %{}})

      assert archived[:archived] >= 1
      assert archived_count(ctx.org) == 2

      assert {:ok, %{archived: again}} = RetentionWorker.perform(%Oban.Job{args: %{}})
      refute Map.has_key?(again, :archived)
    end
  end
end
