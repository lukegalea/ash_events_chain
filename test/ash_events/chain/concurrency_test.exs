# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.ConcurrencyTest do
  @moduledoc """
  Concurrent appends to one chain stay linear because each writer holds the chain's
  advisory lock from before its insert until it commits.

  These tests commit for real, on connections outside the sandbox, because the
  property is about separate transactions. Each cleans up with `TRUNCATE`, which the
  row triggers do not see.
  """

  use ExUnit.Case, async: false

  alias AshEvents.Chain
  alias AshEvents.Chain.LockKeyGenerator
  alias AshEvents.Chain.Test.{EventLog, Note, Setting}
  alias AshEvents.Chain.TestRepo
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    on_exit(fn ->
      unboxed(fn -> TestRepo.query!("TRUNCATE audit_events, notes, settings") end)
    end)

    %{org: Ash.UUID.generate()}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(TestRepo, fun)

  defp insert_raw!(org) do
    TestRepo.query!(
      "INSERT INTO audit_events (record_id, metadata, occurred_at, resource, action, action_type) " <>
        "VALUES (gen_random_uuid(), $1::jsonb, now(), 'Elixir.Probe', 'create', 'create')",
      [%{"organization_id" => org}]
    )
  end

  # Runs `fun` in a transaction that gives up on a lock after 300ms, and returns what it
  # returned or raised.
  defp within_lock_timeout(fun) do
    {:error, result} =
      unboxed(fn ->
        TestRepo.transaction(fn ->
          TestRepo.query!("SET LOCAL lock_timeout = '300ms'")

          result =
            try do
              fun.()
            rescue
              error -> error
            end

          TestRepo.rollback(result)
        end)
      end)

    result
  end

  defp linked?(org) do
    rows =
      TestRepo.query!(
        "SELECT hash, previous_hash FROM audit_events WHERE organization_id = $1::uuid ORDER BY sequence",
        [Ecto.UUID.dump!(org)]
      ).rows

    previouses = Enum.map(rows, &Enum.at(&1, 1))
    hashes = Enum.map(rows, &Enum.at(&1, 0))
    previouses == [nil | Enum.drop(hashes, -1)]
  end

  test "concurrent audited writes to one chain stay linear", ctx do
    writers =
      for n <- 1..20 do
        Task.async(fn ->
          unboxed(fn ->
            Note
            |> Ash.Changeset.for_create(:create, %{body: "note #{n}"}, tenant: ctx.org)
            |> Ash.create!()
          end)
        end)
      end

    Task.await_many(writers, 30_000)

    unboxed(fn ->
      assert linked?(ctx.org)
      assert %{findings: [], checked: 20} = Chain.verify(EventLog, ctx.org)
    end)
  end

  # The trigger alone does not serialize: a second transaction reads the tail without
  # the first one's uncommitted row, and both link to the same predecessor. This is
  # what the lock prevents, shown without it.
  test "without the lock, two transactions fork the chain", ctx do
    parent = self()

    first =
      Task.async(fn ->
        unboxed(fn ->
          TestRepo.transaction(fn ->
            insert_raw!(ctx.org)
            send(parent, :first_inserted)
            assert_receive :commit, 5_000
          end)
        end)
      end)

    assert_receive :first_inserted, 5_000
    unboxed(fn -> insert_raw!(ctx.org) end)
    send(first.pid, :commit)
    Task.await(first)

    unboxed(fn ->
      assert %{findings: [%{problem: :broken_link}]} = Chain.verify(EventLog, ctx.org)
    end)
  end

  test "a writer waits for the chain's lock", ctx do
    key = LockKeyGenerator.key_for(ctx.org, nil)
    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          TestRepo.transaction(fn ->
            TestRepo.query!("SELECT pg_advisory_xact_lock($1, $2)", key)
            send(parent, :locked)
            assert_receive :release, 5_000
          end)
        end)
      end)

    assert_receive :locked, 5_000

    blocked =
      within_lock_timeout(fn ->
        Note
        |> Ash.Changeset.for_create(:create, %{body: "waits"}, tenant: ctx.org)
        |> Ash.create()
      end)

    assert inspect(blocked) =~ "lock timeout"

    send(holder.pid, :release)
    Task.await(holder)
  end

  # A resource without multitenancy, whose events carry the organization in their
  # metadata, joins that organization's chain. AshEvents' default key would give its
  # writes the shared default integer, a lock no tenant-scoped writer to the same
  # chain takes. The chain's generator gives it the organization's key.
  test "an untenanted resource stamped with a partition takes that chain's lock", ctx do
    changeset = Ash.Changeset.for_create(Setting, :create, %{key: "k"}, tenant: ctx.org)

    assert AshEvents.AdvisoryLockKeyGenerator.Default.generate_key!(changeset, 7) == 7
    assert LockKeyGenerator.generate_key!(changeset, 7) == LockKeyGenerator.key_for(ctx.org, 7)

    parent = self()

    holder =
      Task.async(fn ->
        unboxed(fn ->
          TestRepo.transaction(fn ->
            TestRepo.query!(
              "SELECT pg_advisory_xact_lock($1, $2)",
              LockKeyGenerator.key_for(ctx.org, nil)
            )

            send(parent, :locked)
            assert_receive :release, 5_000
          end)
        end)
      end)

    assert_receive :locked, 5_000

    blocked = within_lock_timeout(fn -> Ash.create(changeset) end)

    assert inspect(blocked) =~ "lock timeout"

    send(holder.pid, :release)
    Task.await(holder)
  end

  test "the key for a tenant is the key AshEvents' default generator gives it", ctx do
    changeset = Ash.Changeset.for_create(Note, :create, %{body: "x"}, tenant: ctx.org)

    assert LockKeyGenerator.generate_key!(changeset, 7) ==
             AshEvents.AdvisoryLockKeyGenerator.Default.generate_key!(changeset, 7)

    assert LockKeyGenerator.key_for(nil, 7) == 7
    assert LockKeyGenerator.key_for(42, 7) == 42
    assert [_, _] = LockKeyGenerator.key_for("not-a-uuid", 7)
  end
end
