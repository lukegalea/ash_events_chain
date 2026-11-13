# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.SQL do
  @moduledoc """
  The chain's SQL, built in one place from a log's chain spec (`AshEvents.Chain.Info`).

  The trigger writes the digest and the verifier recomputes it, both from
  `hash_expression/3`. Two implementations of one canonical form is how a verifier
  ends up disagreeing with the trigger about `NULL`s, JSON key order and timestamp
  formatting, and a verifier that reports false breaks gets switched off.

  ## The canonical form

  A row's hash is the hex SHA-256 of

      concat_ws('|', coalesce(previous_hash, ''), <column>, <column>, ...)

  over the log's digest columns, in order. Each column is cast to `text` and
  rendered in one of two ways:

    * `column` - `coalesce(column::text, '')`: a `NULL` is an empty field, so the
      separators stay where they were.
    * `{column, :omit_nil}` - `column::text`: `concat_ws` leaves a `NULL` out. A
      column added this way does not change the digest of a row where it is
      `NULL`, so rows written before the column existed still verify.

  ## Identifiers

  Every table, column and function name in this SQL comes from the resource
  definitions, checked against `identifier?/1` at compile time. No value is ever
  interpolated: values are bound parameters.

  ## Floors

  The triggers hold two numbers whatever a deployment configures: a hot row is
  deleted only once it is 90 days old and identical in the archive, and an
  archived row only once it is 400 days old.
  """

  @hot_floor_days 90
  @purge_floor_days 400

  @typedoc "A digest column with its `NULL` rendering."
  @type digest_column :: {atom(), :empty_if_nil | :omit_nil}

  @doc "The fewest days a row stays in the hot table."
  @spec hot_floor_days() :: pos_integer()
  def hot_floor_days, do: @hot_floor_days

  @doc "The fewest days a row is kept at all."
  @spec purge_floor_days() :: pos_integer()
  def purge_floor_days, do: @purge_floor_days

  @doc "Whether `name` is a plain lower-case SQL identifier, safe to splice into SQL."
  @spec identifier?(term()) :: boolean()
  def identifier?(name) when is_atom(name), do: identifier?(Atom.to_string(name))
  def identifier?(name) when is_binary(name), do: name =~ ~r/^[a-z_][a-z0-9_]{0,62}$/
  def identifier?(_), do: false

  @doc """
  Normalises a `digest_columns:` list: a bare atom becomes `{atom, :empty_if_nil}`.
  """
  @spec normalize_digest_columns([atom() | {atom(), :omit_nil}]) :: [digest_column()]
  def normalize_digest_columns(columns) do
    Enum.map(columns, fn
      column when is_atom(column) -> {column, :empty_if_nil}
      {column, :omit_nil} when is_atom(column) -> {column, :omit_nil}
      other -> raise ArgumentError, "invalid digest column #{inspect(other)}"
    end)
  end

  @doc """
  The `concat_ws('|', ...)` digest input. `prefix` is the row prefix (`"NEW."` in
  the trigger, `""` in the verifier); `previous` is the SQL for the previous hash.
  """
  @spec digest_input([digest_column()], String.t(), String.t()) :: String.t()
  def digest_input(digest_columns, prefix, previous) do
    values =
      Enum.map(digest_columns, fn
        {column, :omit_nil} -> "#{prefix}#{column}::text"
        {column, :empty_if_nil} -> "coalesce(#{prefix}#{column}::text, '')"
      end)

    "concat_ws('|',\n      " <>
      Enum.join(["coalesce(#{previous}, '')" | values], ",\n      ") <> ")"
  end

  @doc "The hex SHA-256 of `digest_input/3`."
  @spec hash_expression([digest_column()], String.t(), String.t()) :: String.t()
  def hash_expression(digest_columns, prefix, previous) do
    "encode(sha256(convert_to(#{digest_input(digest_columns, prefix, previous)}, 'UTF8')), 'hex')"
  end

  @doc """
  The `BEFORE INSERT` chain function: sets the partition from the metadata when the
  log takes it from there, reads the tail of the row's chain, and sets
  `previous_hash` and `hash`.
  """
  @spec chain_function(map()) :: String.t()
  def chain_function(spec) do
    %{table: table, partition: p, chain_function: function} = spec

    """
    CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $fn$
    DECLARE
      prev text;
    BEGIN
    #{partition_assignment(spec)}
      -- The tail of the row's chain, read backwards off the chain index. The two
      -- cases are written apart because `IS NOT DISTINCT FROM` cannot use the index,
      -- and the index's own order lets the planner see that an `IS NULL` match is
      -- already ordered by sequence.
      IF NEW.#{p} IS NULL THEN
        SELECT hash INTO prev
        FROM #{table}
        WHERE #{p} IS NULL
        ORDER BY #{p} DESC, sequence DESC
        LIMIT 1;
      ELSE
        SELECT hash INTO prev
        FROM #{table}
        WHERE #{p} = NEW.#{p}
        ORDER BY #{p} DESC, sequence DESC
        LIMIT 1;
      END IF;

      NEW.previous_hash := prev;
      NEW.hash := #{hash_expression(spec.digest_columns, "NEW.", "prev")};

      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;
    """
  end

  defp partition_assignment(%{partition_metadata_key: nil}), do: ""

  defp partition_assignment(%{partition: p, partition_metadata_key: key, partition_sql_type: t}) do
    """
      -- The partition is taken from the event's metadata rather than from the caller,
      -- so the column and the metadata cannot disagree.
      NEW.#{p} := NULLIF(NEW.metadata->>'#{key}', '')::#{t};
    """
  end

  @doc """
  The chain trigger. Its SQL carries a digest of the chain function, so a change to
  the function changes this statement too: the migration then drops the trigger
  before the function and creates it again after.
  """
  @spec chain_trigger(map()) :: String.t()
  def chain_trigger(%{table: table, chain_function: function} = spec) do
    """
    -- #{function}: #{short_digest(chain_function(spec))}
    CREATE OR REPLACE TRIGGER #{table}_chain
      BEFORE INSERT ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    """
  end

  @doc """
  The immutability function for the hot table. `UPDATE` and `DELETE` raise, except a
  `DELETE` of a row at least #{@hot_floor_days} days old whose identical copy is
  already in the archive table (when the log has one).
  """
  @spec immutable_function(map()) :: String.t()
  def immutable_function(%{table: table, immutable_function: function} = spec) do
    """
    CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $fn$
    BEGIN
    #{retention_delete_clause(spec)}
      RAISE EXCEPTION '#{table} is append-only; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation',
              HINT = 'Correct a wrong entry by recording a new one.';
    END;
    $fn$ LANGUAGE plpgsql;
    """
  end

  defp retention_delete_clause(%{archive_table: nil}), do: ""

  defp retention_delete_clause(%{archive_table: archive} = spec) do
    columns = Enum.reject(spec.copied_columns, &(&1 == :id))
    archived = Enum.map_join(columns, ", ", &"a.#{&1}")
    old = Enum.map_join(columns, ", ", &"OLD.#{&1}")

    """
      -- The one DELETE allowed: retention moving a row out of the hot table. The row
      -- must be past the hot floor, and an identical copy must already be archived,
      -- so a row can leave this table only by having arrived there first.
      IF TG_OP = 'DELETE'
         AND OLD.occurred_at < now() - interval '#{@hot_floor_days} days'
         AND EXISTS (
           SELECT 1 FROM #{archive} a
           WHERE a.id = OLD.id
             AND (#{archived}) IS NOT DISTINCT FROM (#{old})
         ) THEN
        RETURN OLD;
      END IF;
    """
  end

  @doc """
  The immutability trigger. Row-level on purpose: `TRUNCATE` stays allowed, because a
  reset has to work and a `TRUNCATE` is not a quiet edit.
  """
  @spec immutable_trigger(map()) :: String.t()
  def immutable_trigger(%{table: table, immutable_function: function} = spec) do
    """
    -- #{function}: #{short_digest(immutable_function(spec))}
    CREATE OR REPLACE TRIGGER #{table}_immutable
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    """
  end

  @doc """
  The archive table's guard: `UPDATE` raises, and so does a `DELETE` of a row younger
  than #{@purge_floor_days} days.
  """
  @spec archive_guard_function(String.t(), String.t()) :: String.t()
  def archive_guard_function(table, function) do
    """
    CREATE OR REPLACE FUNCTION #{function}() RETURNS trigger AS $fn$
    BEGIN
      IF TG_OP = 'DELETE' AND OLD.occurred_at < now() - interval '#{@purge_floor_days} days' THEN
        RETURN OLD;
      END IF;

      RAISE EXCEPTION '#{table} keeps every event for #{@purge_floor_days} days; % is not permitted', TG_OP
        USING ERRCODE = 'restrict_violation',
              HINT = 'Archived events are never edited, and are purged only after #{@purge_floor_days} days.';
    END;
    $fn$ LANGUAGE plpgsql;
    """
  end

  @doc "The archive guard trigger, carrying a digest of its function like `chain_trigger/1`."
  @spec archive_guard_trigger(String.t(), String.t()) :: String.t()
  def archive_guard_trigger(table, function) do
    """
    -- #{function}: #{short_digest(archive_guard_function(table, function))}
    CREATE OR REPLACE TRIGGER #{table}_guard
      BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION #{function}();
    """
  end

  @doc "`DROP FUNCTION`, without `CASCADE`: a trigger is dropped by its own statement."
  @spec drop_function(String.t()) :: String.t()
  def drop_function(function), do: "DROP FUNCTION IF EXISTS #{function}();"

  @doc "`DROP TRIGGER` on `table`."
  @spec drop_trigger(String.t(), String.t()) :: String.t()
  def drop_trigger(table, trigger), do: "DROP TRIGGER IF EXISTS #{trigger} ON #{table};"

  @doc """
  The verification query for one chain.

  Hot and archived rows are one chain: with an archive table the query reads both,
  and `UNION` (not `UNION ALL`) folds a row that is in both tables during a move into
  one, while two different rows at one position stay two and break the link.

  Parameters, for a partition: `$1` the partition value, `$2` the anchor hash (the
  last purged row's hash, or `NULL`), `$3` the sequence the chain starts after. For
  the chain with no partition value, `$1` the anchor and `$2` the sequence.
  """
  @spec verify_query(map(), :partition | :null_partition) :: String.t()
  def verify_query(spec, which) do
    {filter, anchor, after_param} =
      case which do
        :partition -> {"#{spec.partition} = $1::#{spec.partition_sql_type}", "$2", "$3"}
        :null_partition -> {"#{spec.partition} IS NULL", "$1", "$2"}
      end

    columns = Enum.join(spec.copied_columns, ", ")

    source =
      case spec.archive_table do
        nil ->
          "SELECT #{columns} FROM #{spec.table} WHERE #{filter}"

        archive ->
          "SELECT #{columns} FROM #{spec.table} WHERE #{filter}\n  UNION\n  " <>
            "SELECT #{columns} FROM #{archive} WHERE #{filter}"
      end

    previous = "lag(hash, 1, #{anchor}::text) OVER (ORDER BY sequence)"

    """
    WITH events AS (
      #{source}
    ),
    chained AS (
      SELECT
        sequence,
        id,
        occurred_at,
        hash,
        previous_hash,
        #{previous} AS actual_previous,
        #{hash_expression(spec.digest_columns, "", previous)} AS recomputed
      FROM events
      WHERE sequence > #{after_param}
    )
    SELECT sequence, id, occurred_at, hash, previous_hash, actual_previous, recomputed
    FROM chained
    ORDER BY sequence
    """
  end

  @doc """
  A filter on `column` for one chain, always on `$1`: a partition value by equality and
  the chain with no value by `IS NULL` (with `$1` null), so each can use the index.
  """
  @spec chain_filter(String.t(), String.t()) :: String.t()
  def chain_filter(column, sql_type),
    do: "((#{column} = $1::#{sql_type}) OR ($1::#{sql_type} IS NULL AND #{column} IS NULL))"

  @doc "SHA-256 over the hashes of a run of rows, in sequence order."
  @spec run_digest(String.t()) :: String.t()
  def run_digest(alias) do
    "encode(sha256(convert_to(coalesce(string_agg(coalesce(#{alias}.hash, '-'), '|' " <>
      "ORDER BY #{alias}.sequence), ''), 'UTF8')), 'hex')"
  end

  defp short_digest(sql),
    do: :crypto.hash(:sha256, sql) |> Base.encode16(case: :lower) |> binary_part(0, 16)
end
