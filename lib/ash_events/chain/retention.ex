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
  the verifier found it. A chain whose verification raises is not moved either: it is
  recorded as a `:failed` run with the error as its reason, and every other chain is
  still archived. Then, in one transaction, the move copies the rows, compares
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

  **A backlog drains over runs.** One move takes at most `:batch_size` rows. A call
  takes up to `:max_batches` moves from each chain, and stops taking further batches
  once `:deadline_ms` has passed (each chain still gets its first). What is still
  eligible after the last batch is the chain's backlog: the last step of each chain
  carries it as `backlog` in its run's metadata (`backlog/1` adds them up), a verified
  run that leaves one says so in its `reason`, and a
  `[:ash_events_chain, :retention, :chain]` telemetry event reports it. The next call
  carries on from there.

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
    * `:max_batches` - the most moves or purges one call takes from each chain.
      Default 1.
    * `:deadline_ms` - after this many milliseconds from the start of the call, no
      chain takes a further batch beyond its first. Default: no deadline.
    * `:actor`, `:authorize?` - how the run ledger's `:record` action is called.
      Default: no actor, `authorize?: true`, so a host passes the actor its policies
      allow.

  `archive/2` also takes `:hot_days` (default #{AshEvents.Chain.SQL.hot_floor_days()}),
  and `:verifier`, the function that verifies one chain before it is moved, called as
  `verifier.(log, partition)` (default `AshEvents.Chain.verify/2`). `purge/2` takes
  `:purge_after_days` (default `nil`, never).

  ## Telemetry

  `[:ash_events_chain, :retention, :chain]`, once per chain a call looked at. The
  measurements are `rows` (moved or purged), `batches` and `backlog` (still eligible
  afterwards; 0 when not known, after a verification that raised). The metadata is
  `log`, `store`, `kind` (`:archive` or `:purge`), `partition` and `status`
  (`:verified`, `:failed` or `:nothing`).

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

  @typedoc "What one move or purge did, or `:nothing` for a chain with nothing eligible."
  @type step :: :nothing | {:archived, struct()} | {:purged, struct()} | {:failed, struct()}

  @doc """
  Moves every chain's events past the hot window to the archive, each move verified.

  Returns `{:ok, steps}`, one step per batch moved (one per chain with the default
  `:max_batches`), or `{:error, {:below_floor, :hot_days, floor}}` when `:hot_days` is
  under the floor.
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
      bounds = bounds(opts, batch)

      steps =
        spec
        |> chains(spec.table)
        |> Enum.flat_map(&archive_chain(spec, &1, cutoff, now, bounds, opts))

      {:ok, steps}
    end
  end

  @doc """
  The rows still eligible after `steps`: the sum of the `backlog` each chain's last
  step carries in its run's metadata.
  """
  @spec backlog([step()] | :disabled) :: non_neg_integer()
  def backlog(:disabled), do: 0

  def backlog(steps) do
    Enum.reduce(steps, 0, fn
      {_kind, %{__metadata__: %{backlog: n}}}, acc when is_integer(n) -> acc + n
      _step, acc -> acc
    end)
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
        bounds = bounds(opts, batch)

        steps =
          spec
          |> chains(spec.archive_table)
          |> Enum.flat_map(&purge_chain(spec, &1, cutoff, bounds, opts))

        {:ok, steps}

      _ ->
        {:error, {:below_floor, :purge_after_days, floor}}
    end
  end

  # --- archive ------------------------------------------------------------------

  defp archive_chain(spec, partition, cutoff, now, bounds, opts) do
    verifier = Keyword.get(opts, :verifier, &Chain.verify/2)

    refused = fn reason ->
      step =
        fail(spec, opts, %{
          kind: :archive,
          partition: partition,
          cutoff: cutoff,
          row_count: 0,
          reason: reason
        })

      emit(spec, :archive, partition, [step], nil)
      [step]
    end

    case Chain.verify_isolated(spec.log, partition, verifier) do
      {:ok, %{findings: []}} ->
        drain(spec, :archive, partition, bounds, fn backlog_reason ->
          case boundary(spec, spec.table, partition, cutoff, bounds.batch, keep_tail?: true) do
            nil ->
              nil

            {from, to, count, eligible} ->
              left = eligible - count

              {move_chain(
                 spec,
                 partition,
                 {from, to, count},
                 cutoff,
                 now,
                 backlog_reason.(left),
                 opts
               ), left}
          end
        end)

      {:ok, %{findings: findings}} ->
        refused.("the chain has #{length(findings)} verification finding(s); nothing was moved")

      {:error, message} ->
        refused.("the chain's verification raised, so nothing was moved: #{message}")
    end
  end

  # sobelow_skip ["SQL.Query"]
  defp move_chain(spec, partition, {from, to, count}, cutoff, now, note, opts) do
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
            cutoff: cutoff,
            reason: note
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

  defp purge_chain(spec, partition, cutoff, bounds, opts) do
    drain(spec, :purge, partition, bounds, fn backlog_reason ->
      case boundary(spec, spec.archive_table, partition, cutoff, bounds.batch, keep_tail?: false) do
        nil ->
          nil

        {from, to, count, eligible} ->
          left = eligible - count

          {purge_range(spec, partition, {from, to, count}, cutoff, backlog_reason.(left), opts),
           left}
      end
    end)
  end

  # sobelow_skip ["SQL.Query"]
  defp purge_range(spec, partition, {from, to, count}, cutoff, note, opts) do
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
          cutoff: cutoff,
          reason: note
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

  # --- draining a chain ---------------------------------------------------------

  defp bounds(opts, batch) do
    deadline =
      case Keyword.get(opts, :deadline_ms) do
        nil -> nil
        ms when is_integer(ms) and ms >= 0 -> System.monotonic_time(:millisecond) + ms
      end

    %{batch: batch, max_batches: max(Keyword.get(opts, :max_batches) || 1, 1), deadline: deadline}
  end

  # Takes batches from one chain with `take`, until nothing is eligible, a batch fails,
  # `:max_batches` is reached or the deadline has passed. `take` is given a function
  # that turns what the batch leaves eligible into the run's reason: a note when this
  # is the chain's last batch and rows remain, otherwise nil. It returns
  # `{step, left}`, or nil when nothing is eligible. The last step carries what is
  # left as `backlog` metadata.
  defp drain(spec, kind, partition, bounds, take),
    do: drain(spec, kind, partition, bounds, take, [])

  defp drain(spec, kind, partition, bounds, take, acc) do
    # The batch about to be taken is the chain's last when it reaches `:max_batches` or
    # the deadline has passed; it is taken either way, so every chain gets its first.
    last? = length(acc) + 1 >= bounds.max_batches or past?(bounds.deadline)
    reason = fn left -> if last? and left > 0, do: backlog_note(left) end

    case take.(reason) do
      nil when acc == [] ->
        emit(spec, kind, partition, [], 0)
        [:nothing]

      nil ->
        done(spec, kind, partition, acc, 0)

      {{:failed, run}, _left} ->
        # Nothing of this batch moved, so what was eligible before it still is.
        done(spec, kind, partition, [{:failed, run} | acc], nil)

      {step, left} when last? or left == 0 ->
        done(spec, kind, partition, [step | acc], left)

      {step, _left} ->
        drain(spec, kind, partition, bounds, take, [step | acc])
    end
  end

  defp done(spec, kind, partition, [last | rest], backlog) do
    last = if is_integer(backlog), do: with_backlog(last, backlog), else: last
    steps = Enum.reverse([last | rest])
    emit(spec, kind, partition, steps, backlog)
    steps
  end

  defp with_backlog({kind, run}, backlog),
    do: {kind, Ash.Resource.put_metadata(run, :backlog, backlog)}

  defp past?(nil), do: false
  defp past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp backlog_note(left),
    do: "#{left} eligible row(s) remain past this run's bound; the next run continues"

  defp emit(spec, kind, partition, steps, backlog) do
    rows =
      Enum.reduce(steps, 0, fn
        {done, run}, acc when done in [:archived, :purged] -> acc + run.row_count
        _step, acc -> acc
      end)

    status =
      cond do
        Enum.any?(steps, &match?({:failed, _}, &1)) -> :failed
        rows > 0 -> :verified
        true -> :nothing
      end

    :telemetry.execute(
      [:ash_events_chain, :retention, :chain],
      %{rows: rows, batches: length(steps), backlog: backlog || 0},
      %{log: spec.log, store: spec.store, kind: kind, partition: partition, status: status}
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
  # Also returns how many rows were eligible before the batch limit.
  defp boundary(spec, table, partition, cutoff, batch, keep_tail?: keep_tail?) do
    tail_clause = if keep_tail?, do: "AND sequence < (SELECT max(sequence) FROM chain)", else: ""
    filter = SQL.chain_filter(Atom.to_string(spec.partition), spec.partition_sql_type)

    %{rows: [[from, to, count, eligible]]} =
      Chain.repo(spec).query!(
        """
        WITH chain AS (
          SELECT sequence, occurred_at FROM #{table} WHERE #{filter}
        ),
        candidates AS (
          SELECT sequence FROM chain
          WHERE occurred_at < $2
            AND sequence < coalesce(
              (SELECT min(sequence) FROM chain WHERE occurred_at >= $2), 9223372036854775807)
            #{tail_clause}
        ),
        eligible AS (
          SELECT sequence FROM candidates ORDER BY sequence LIMIT $3
        )
        SELECT min(sequence), max(sequence), count(*), (SELECT count(*) FROM candidates)
        FROM eligible
        """,
        [Info.dump_partition(spec, partition), cutoff, batch]
      )

    if count == 0, do: nil, else: {from, to, count, eligible}
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
