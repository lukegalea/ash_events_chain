# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain do
  @moduledoc """
  A tamper-evident hash chain for an `AshEvents.EventLog` table, and its verifier.

  A chained log (`AshEvents.Chain.Resources`, `{:chained_log, opts}`) links every
  event to the one before it in its chain. A `BEFORE INSERT` trigger sets each row's
  `previous_hash` to the hash of the chain's last row and its `hash` to the SHA-256
  of its own digest columns and `previous_hash`. A second trigger refuses `UPDATE`
  and `DELETE`. The trigger prevents; the chain detects what the trigger could not
  prevent, such as an edit made with the trigger disabled.

  There is one chain per partition value (usually the tenant), plus one for events
  with none. AshEvents already takes an advisory lock before it inserts an event;
  with `AshEvents.Chain.LockKeyGenerator` that lock is keyed on the partition the
  trigger chains on, so appends to one chain are serialized and the chain stays
  linear, without serializing writes to other chains.

  ## Findings

  `verify/2` walks one chain in sequence order and recomputes each hash in SQL with
  the trigger's own expression (`AshEvents.Chain.SQL`). Three findings, because they
  have different causes:

    * `:altered` - a row's stored hash does not match its contents. Someone changed
      the row.
    * `:broken_link` - a row's `previous_hash` is not the hash of the row before it.
      Someone removed a row, or inserted one out of band.
    * `:unchained` - a row has no hash, after rows that do. The insert trigger was
      disabled.

  Rows written before the chain existed have no hash either. An unbroken run of them
  at the start of a chain is counted in `skipped_unchained_prefix` and is not a
  finding.

  ## Hot, archived and purged rows

  With an archive (`{:archive, opts}`), the verifier reads the hot table and the
  archive as one chain. After a purge (`AshEvents.Chain.Retention.purge/2`), it
  starts from the last verified purge in the run ledger: the first remaining row
  must link to the purged row's hash, recorded as the run's `tail_hash`.

  The verifier reads with raw SQL and no actor. It is machinery: it reports on the
  log, and what the report may show is the caller's decision.
  """

  alias AshEvents.Chain.{Info, SQL}

  @type finding :: %{
          sequence: integer(),
          id: term(),
          occurred_at: DateTime.t(),
          problem: :altered | :broken_link | :unchained
        }

  @type result :: %{
          partition: term(),
          anchored_after: integer() | nil,
          checked: non_neg_integer(),
          skipped_unchained_prefix: non_neg_integer(),
          findings: [finding()]
        }

  @doc """
  Verifies one chain of `log`. `nil` verifies the chain of events with no partition
  value. Returns a summary; `findings: []` is a clean chain.
  """
  @spec verify(module(), term()) :: result()
  def verify(log, partition) do
    spec = Info.spec!(log)
    {anchor_hash, after_sequence} = anchor(spec, partition)

    %{rows: rows} =
      case partition do
        nil ->
          repo(spec).query!(SQL.verify_query(spec, :null_partition), [
            anchor_hash,
            after_sequence
          ])

        value ->
          repo(spec).query!(SQL.verify_query(spec, :partition), [
            Info.dump_partition(spec, value),
            anchor_hash,
            after_sequence
          ])
      end

    # Rows predating the chain carry no hash. They are ignorable only while they form
    # an unbroken run at the very start: an unchained row after a chained one is the
    # trigger having been disabled.
    {unchained_prefix, chained} =
      Enum.split_while(rows, fn [_, _, _, hash | _] -> is_nil(hash) end)

    %{
      partition: partition,
      anchored_after: if(anchor_hash, do: after_sequence),
      checked: length(chained),
      skipped_unchained_prefix: length(unchained_prefix),
      findings: chained |> Enum.map(&examine(spec, &1)) |> Enum.reject(&is_nil/1)
    }
  end

  @doc """
  Verifies every chain of `log`, hot and archived: one per partition value, plus the
  chain with none.
  """
  @spec verify_all(module()) :: [result()]
  def verify_all(log) do
    log |> partitions() |> Enum.map(&verify(log, &1))
  end

  @doc "Whether every result in `results` is clean."
  @spec clean?([result()]) :: boolean()
  def clean?(results), do: Enum.all?(results, &(&1.findings == []))

  @doc """
  Every partition value present in `log`'s hot table and archive, `nil` first.
  """
  @spec partitions(module()) :: [term()]
  # sobelow_skip ["SQL.Query"]
  def partitions(log) do
    spec = Info.spec!(log)
    p = spec.partition

    sql =
      case spec.archive_table do
        nil ->
          "SELECT DISTINCT #{p} FROM #{spec.table} ORDER BY 1 NULLS FIRST"

        archive ->
          "SELECT #{p} FROM #{spec.table} UNION SELECT #{p} FROM #{archive} ORDER BY 1 NULLS FIRST"
      end

    %{rows: rows} = repo(spec).query!(sql, [])
    Enum.map(rows, fn [value] -> Info.load_partition(spec, value) end)
  end

  @doc false
  def repo(spec), do: AshPostgres.DataLayer.Info.repo(spec.log, :mutate)

  # Where the chain starts after a purge: the newest verified purge's tail hash and
  # last sequence. With none, the chain starts at its first row.
  # sobelow_skip ["SQL.Query"]
  defp anchor(%{archive_run: nil}, _partition), do: {nil, -1}

  defp anchor(spec, partition) do
    run = spec.archive_run
    %{chain_attribute: column} = Spark.Dsl.Extension.get_persisted(run, :ash_events_chain_run)
    table = AshPostgres.DataLayer.Info.table(run)

    sql = """
    SELECT tail_hash, to_sequence FROM #{table}
    WHERE store = $2 AND kind = 'purge' AND status = 'verified'
      AND #{SQL.chain_filter(Atom.to_string(column), spec.partition_sql_type)}
    ORDER BY to_sequence DESC
    LIMIT 1
    """

    case repo(spec).query!(sql, [Info.dump_partition(spec, partition), Atom.to_string(spec.store)]) do
      %{rows: [[hash, sequence]]} when is_binary(hash) -> {hash, sequence}
      _ -> {nil, -1}
    end
  end

  defp examine(spec, [sequence, id, occurred_at, hash, previous_hash, actual_previous, recomputed]) do
    finding = fn problem ->
      %{
        sequence: sequence,
        id: Info.load_id(spec, id),
        occurred_at: utc(occurred_at),
        problem: problem
      }
    end

    cond do
      is_nil(hash) -> finding.(:unchained)
      previous_hash != actual_previous -> finding.(:broken_link)
      hash != recomputed -> finding.(:altered)
      true -> nil
    end
  end

  # `occurred_at` is a `timestamp` column holding UTC, which a raw query reads naive.
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(%DateTime{} = at), do: at
end
