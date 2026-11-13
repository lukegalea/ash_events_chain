# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.Retention do
  @moduledoc """
  Moves a chained log's old events to its archive, verifying each move first, and
  purges the archive past a configured age.

  **The hot window.** `archive/2` moves each chain's leading run of events older than
  `:hot_days` (at least #{AshEvents.Chain.SQL.hot_floor_days()}) to the archive table.

  **A verified move.** Each move first verifies the chain (`AshEvents.Chain.verify/2`);
  a chain with a finding is not moved, because a break is evidence and stays where
  the verifier found it. Then, in one transaction, the move copies the rows, compares
  the copy with the hot rows (the same count on both sides, every column equal, the
  same SHA-256 over their hashes in order) and deletes the hot rows only when all of
  that holds and the delete removes exactly the rows that were compared. A failed
  comparison rolls the transaction back, so nothing is copied and nothing deleted,
  and a `:failed` run records why. The database checks the delete again: the hot
  table's trigger refuses it for a row with no identical archived copy or younger
  than #{AshEvents.Chain.SQL.hot_floor_days()} days.

  **The tail stays hot.** A chain's last row is never moved, so the chain trigger
  always finds the row the next event links to.

  **Retrying is safe.** The copy skips a row already in the archive (`ON CONFLICT
  DO NOTHING`) and the comparison then checks the row that is there. A move that is
  retried after its copy landed verifies and completes; one whose archived copy
  differs fails and deletes nothing. A second run finds nothing to move.

  **Purge.** `purge/2` deletes archived rows older than `:purge_after_days` only when
  that is set, and refuses a value under #{AshEvents.Chain.SQL.purge_floor_days()}.
  The archive's trigger refuses a younger row whatever the configuration. A purge
  records the hash of the last purged row, and the verifier starts the remaining
  chain from it.

  ## Options

  For both functions:

    * `:now` - the time the cutoff is counted back from. Default: now.
    * `:batch_size` - the most rows one move or purge takes from a chain. Default
      10,000.
    * `:actor`, `:authorize?` - how the run ledger's `:record` action is called.
      Default: no actor, `authorize?: true`, so a host passes the actor its policies
      allow.

  `archive/2` also takes `:hot_days` (default #{AshEvents.Chain.SQL.hot_floor_days()}),
  and `purge/2` takes `:purge_after_days` (default `nil`, never).

  The log needs an archive table and a run ledger (`:archive_table` and
  `:archive_run` on `{:chained_log, opts}`).

  ## Why this module writes SQL

  The hot table has no write actions (AshEvents appends to it, and its triggers
  refuse everything else), and the archive has none. A move is a set-based copy and
  delete between two tables, checked by triggers in the database. What retention
  records about itself goes through Ash, as the run ledger's `:record` action. The
  SQL is built from table and column names fixed at compile time; every value is a
  bound parameter.
  """

  alias AshEvents.Chain
  alias AshEvents.Chain.{Info, SQL}

  @default_batch 10_000

  @typedoc "What one chain's step did."
  @type step :: :nothing | {:archived, struct()} | {:purged, struct()} | {:failed, struct()}

  @doc """
  Moves every chain's events past the hot window to the archive, each move verified.

  Returns `{:ok, steps}`, one step per chain, or `{:error, {:below_floor, :hot_days,
  floor}}` when `:hot_days` is under the floor.
  """
  @spec archive(module(), keyword()) :: {:ok, [step()]} | {:error, term()}
  def archive(log, opts \\ []) do
    spec = retention_spec!(log)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    days = Keyword.get(opts, :hot_days) || SQL.hot_floor_days()
    batch = Keyword.get(opts, :batch_size) || @default_batch

    if days < SQL.hot_floor_days() do
      {:error, {:below_floor, :hot_days, SQL.hot_floor_days()}}
    else
      cutoff = DateTime.add(now, -days * 86_400, :second)

      steps =
        spec
        |> chains(spec.table)
        |> Enum.map(&archive_chain(spec, &1, cutoff, now, batch, opts))

      {:ok, steps}
    end
  end

  @doc """
  Deletes archived events older than `:purge_after_days`, recording each purge's
  tail hash.

  Returns `{:ok, :disabled}` when no age is set, `{:ok, steps}`, or
  `{:error, {:below_floor, :purge_after_days, floor}}`.
  """
  @spec purge(module(), keyword()) :: {:ok, :disabled | [step()]} | {:error, term()}
  def purge(log, opts \\ []) do
    spec = retention_spec!(log)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    batch = Keyword.get(opts, :batch_size) || @default_batch
    floor = SQL.purge_floor_days()

    case Keyword.get(opts, :purge_after_days) do
      nil ->
        {:ok, :disabled}

      days when is_integer(days) and days >= floor ->
        cutoff = DateTime.add(now, -days * 86_400, :second)

        steps =
          spec
          |> chains(spec.archive_table)
          |> Enum.map(&purge_chain(spec, &1, cutoff, batch, opts))

        {:ok, steps}

      _ ->
        {:error, {:below_floor, :purge_after_days, floor}}
    end
  end

  # --- archive ------------------------------------------------------------------

  defp archive_chain(spec, partition, cutoff, now, batch, opts) do
    case Chain.verify(spec.log, partition) do
      %{findings: []} ->
        case boundary(spec, spec.table, partition, cutoff, batch, keep_tail?: true) do
          nil -> :nothing
          range -> move_chain(spec, partition, range, cutoff, now, opts)
        end

      %{findings: findings} ->
        fail(spec, opts, %{
          kind: :archive,
          partition: partition,
          cutoff: cutoff,
          row_count: 0,
          reason: "the chain has #{length(findings)} verification finding(s); nothing was moved"
        })
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp move_chain(spec, partition, {from, to, count}, cutoff, now, opts) do
    repo = Chain.repo(spec)
    columns = Enum.join(spec.copied_columns, ", ")
    params = [Info.dump_partition(spec, partition), from, to]
    filter = SQL.chain_filter(Atom.to_string(spec.partition), spec.partition_sql_type)

    result =
      repo.transaction(fn ->
        repo.query!(
          "INSERT INTO #{spec.archive_table} (#{columns}, archived_at) " <>
            "SELECT #{columns}, $4 FROM #{spec.table} " <>
            "WHERE #{filter} AND sequence BETWEEN $2 AND $3 " <>
            "ON CONFLICT (id) DO NOTHING",
          params ++ [now]
        )

        with {:ok, digest} <- verify_copy(spec, params, count),
             :ok <- delete_hot(spec, params, count) do
          record!(spec, opts, %{
            kind: :archive,
            status: :verified,
            partition: partition,
            from_sequence: from,
            to_sequence: to,
            row_count: count,
            digest: digest,
            cutoff: cutoff
          })
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        {:archived, run}

      {:error, reason} ->
        fail(spec, opts, failure(:archive, partition, from, to, count, cutoff, reason))
    end
  rescue
    # The database refused, most likely the immutability trigger. The transaction
    # rolled back, so nothing was copied and nothing deleted.
    error in Postgrex.Error ->
      fail(
        spec,
        opts,
        failure(:archive, partition, from, to, count, cutoff, Exception.message(error))
      )
  end

  # The copy matches the hot rows: the same count on both sides of the range, every
  # column of every row equal, and the same digest over the hashes in order.
  # sobelow_skip ["SQL.Query"]
  defp verify_copy(spec, params, count) do
    filter = &SQL.chain_filter(&1, spec.partition_sql_type)
    p = spec.partition
    archive = spec.archive_table
    range = "BETWEEN $2 AND $3"

    same_row =
      "(#{Enum.map_join(spec.copied_columns, ", ", &"a.#{&1}")}) IS NOT DISTINCT FROM " <>
        "(#{Enum.map_join(spec.copied_columns, ", ", &"h.#{&1}")})"

    %{rows: [[hot, archived, matching, hot_digest, archive_digest]]} =
      Chain.repo(spec).query!(
        """
        SELECT
          (SELECT count(*) FROM #{spec.table} h
             WHERE #{filter.("h.#{p}")} AND h.sequence #{range}),
          (SELECT count(*) FROM #{archive} a
             WHERE #{filter.("a.#{p}")} AND a.sequence #{range}),
          (SELECT count(*) FROM #{spec.table} h
             JOIN #{archive} a ON a.id = h.id AND #{same_row}
             WHERE #{filter.("h.#{p}")} AND h.sequence #{range}),
          (SELECT #{SQL.run_digest("h")} FROM #{spec.table} h
             WHERE #{filter.("h.#{p}")} AND h.sequence #{range}),
          (SELECT #{SQL.run_digest("a")} FROM #{archive} a
             WHERE #{filter.("a.#{p}")} AND a.sequence #{range})
        """,
        params
      )

    cond do
      hot != count -> {:error, "hot rows changed under the move: #{hot} for #{count}"}
      archived != count -> {:error, "archive holds #{archived} rows for #{count} hot rows"}
      matching != count -> {:error, "#{count - matching} archived row(s) differ from the hot row"}
      hot_digest != archive_digest -> {:error, "digest mismatch"}
      true -> {:ok, hot_digest}
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp delete_hot(spec, params, count) do
    filter = SQL.chain_filter(Atom.to_string(spec.partition), spec.partition_sql_type)

    %{num_rows: deleted} =
      Chain.repo(spec).query!(
        "DELETE FROM #{spec.table} WHERE #{filter} AND sequence BETWEEN $2 AND $3",
        params
      )

    if deleted == count, do: :ok, else: {:error, "deleted #{deleted} rows for #{count} verified"}
  end

  # --- purge ----------------------------------------------------------------------

  defp purge_chain(spec, partition, cutoff, batch, opts) do
    case boundary(spec, spec.archive_table, partition, cutoff, batch, keep_tail?: false) do
      nil -> :nothing
      range -> purge_range(spec, partition, range, cutoff, opts)
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp purge_range(spec, partition, {from, to, count}, cutoff, opts) do
    repo = Chain.repo(spec)
    archive = spec.archive_table
    params = [Info.dump_partition(spec, partition), from, to]
    filter = &SQL.chain_filter(&1, spec.partition_sql_type)
    p = Atom.to_string(spec.partition)

    result =
      repo.transaction(fn ->
        %{rows: [[tail_hash, digest]]} =
          repo.query!(
            """
            SELECT
              (SELECT hash FROM #{archive} WHERE #{filter.(p)} AND sequence = $3),
              (SELECT #{SQL.run_digest("a")} FROM #{archive} a
                 WHERE #{filter.("a.#{p}")} AND a.sequence BETWEEN $2 AND $3)
            """,
            params
          )

        %{num_rows: deleted} =
          repo.query!(
            "DELETE FROM #{archive} WHERE #{filter.(p)} AND sequence BETWEEN $2 AND $3",
            params
          )

        if deleted != count, do: repo.rollback("deleted #{deleted} rows for #{count}")

        record!(spec, opts, %{
          kind: :purge,
          status: :verified,
          partition: partition,
          from_sequence: from,
          to_sequence: to,
          row_count: count,
          digest: digest,
          tail_hash: tail_hash,
          cutoff: cutoff
        })
      end)

    case result do
      {:ok, run} ->
        {:purged, run}

      {:error, reason} ->
        fail(spec, opts, failure(:purge, partition, from, to, count, cutoff, reason))
    end
  rescue
    error in Postgrex.Error ->
      fail(
        spec,
        opts,
        failure(:purge, partition, from, to, count, cutoff, Exception.message(error))
      )
  end

  # --- shared ---------------------------------------------------------------------

  defp retention_spec!(log) do
    spec = Info.spec!(log)

    if is_nil(spec.archive_table) or is_nil(spec.archive_run) do
      raise ArgumentError,
            "#{inspect(log)} needs :archive_table and :archive_run on {:chained_log, opts} " <>
              "for retention"
    end

    spec
  end

  # Every chain in a table: one per partition value, plus the chain with none.
  # sobelow_skip ["SQL.Query"]
  defp chains(spec, table) do
    %{rows: rows} =
      Chain.repo(spec).query!(
        "SELECT DISTINCT #{spec.partition} FROM #{table} ORDER BY 1 NULLS FIRST",
        []
      )

    Enum.map(rows, fn [value] -> Info.load_partition(spec, value) end)
  end

  # The leading run of a chain older than the cutoff, at most `batch` rows: every row
  # below the first one at or after the cutoff. In the hot table the chain's last row
  # stays, so the chain trigger always has a row to link the next event to.
  # sobelow_skip ["SQL.Query"]
  defp boundary(spec, table, partition, cutoff, batch, keep_tail?: keep_tail?) do
    tail_clause = if keep_tail?, do: "AND sequence < (SELECT max(sequence) FROM chain)", else: ""
    filter = SQL.chain_filter(Atom.to_string(spec.partition), spec.partition_sql_type)

    %{rows: [[from, to, count]]} =
      Chain.repo(spec).query!(
        """
        WITH chain AS (
          SELECT sequence, occurred_at FROM #{table} WHERE #{filter}
        ),
        eligible AS (
          SELECT sequence FROM chain
          WHERE occurred_at < $2
            AND sequence < coalesce(
              (SELECT min(sequence) FROM chain WHERE occurred_at >= $2), 9223372036854775807)
            #{tail_clause}
          ORDER BY sequence
          LIMIT $3
        )
        SELECT min(sequence), max(sequence), count(*) FROM eligible
        """,
        [Info.dump_partition(spec, partition), cutoff, batch]
      )

    if count == 0, do: nil, else: {from, to, count}
  end

  defp failure(kind, partition, from, to, count, cutoff, reason) do
    %{
      kind: kind,
      partition: partition,
      from_sequence: from,
      to_sequence: to,
      row_count: count,
      cutoff: cutoff,
      reason: reason
    }
  end

  defp record!(spec, opts, attrs) do
    run = spec.archive_run
    %{chain_attribute: column} = Spark.Dsl.Extension.get_persisted(run, :ash_events_chain_run)
    {partition, attrs} = Map.pop(attrs, :partition)

    attrs =
      attrs
      |> Map.put(:store, spec.store)
      |> Map.put(column, partition)

    run
    |> Ash.Changeset.for_create(:record, attrs,
      actor: Keyword.get(opts, :actor),
      authorize?: Keyword.get(opts, :authorize?, true)
    )
    |> Ash.create!()
  end

  defp fail(spec, opts, attrs) do
    reason = attrs |> Map.get(:reason) |> to_reason()
    {:failed, record!(spec, opts, Map.merge(attrs, %{status: :failed, reason: reason}))}
  end

  defp to_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 500)
  defp to_reason(reason), do: reason |> inspect() |> String.slice(0, 500)
end
