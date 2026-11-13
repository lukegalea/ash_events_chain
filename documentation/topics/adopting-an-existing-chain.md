<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Adopting an existing chain

A host that already keeps a hash-chained event log, with its own trigger, its own
archive and its own run ledger, can move onto this package without rewriting a
row. The rows keep verifying because the package can reproduce the host's hash
exactly, and the database objects keep their names.

## 1. Match the hash

The package's hash is

    sha256(concat_ws('|', coalesce(previous_hash, ''), <column>, <column>, ...))

over the digest columns in order, each rendered as text. A bare column renders a
`NULL` as an empty field (`coalesce(col::text, '')`); `{column, :omit_nil}` leaves a
`NULL` out, which is how `concat_ws` treats a column that is not wrapped in
`coalesce`.

If your trigger computed that over the default list (see
`AshEvents.Chain.Resources`), you need nothing. Otherwise pass the list your rows
were hashed over:

```elixir
use AshEvents.Chain.Resources,
    {:chained_log,
     partition: :organization_id,
     digest_columns: [
       :sequence, :id, :record_id, :version, :occurred_at, :resource, :action,
       :action_type, :user_id, :organization_id, :data, :changed_attributes,
       :metadata
     ]}
```

Check it before you switch: for a sample of rows, compare the stored `hash` with
the expression `AshEvents.Chain.SQL.hash_expression/3` builds, or simply run
`AshEvents.Chain.verify_all/1` against a copy of production data with the new
trigger installed.

## 2. Keep the names

The package names its objects after the table:

| Object | Name |
| --- | --- |
| Chain trigger | `<table>_chain` |
| Immutability trigger | `<table>_immutable` |
| Chain index | `<table>_chain_index` |
| Custom statements | `<table>_chain_function`, `<table>_chain_trigger`, `<table>_immutable_function`, `<table>_immutable_trigger` |
| Archive guard trigger | `<archive table>_guard` |
| Archive statements | `<archive table>_guard_function`, `<archive table>_guard_trigger` |
| Archive index | `<archive table>_chain_index` |
| Run ledger index | `<run table>_anchor_index` |

The trigger functions' names are options, so keep yours:
`chain_function:` and `immutable_function:` on `{:chained_log, opts}`, and
`guard_function:` on `{:archive, opts}`. The tables are yours already (the
`postgres` block, and `table:` on the archive and the run ledger).

The run ledger's chain column is `chain_attribute:` (default `:chain_partition`).
Its `store` column holds the log's table name as an atom.

## 3. Remove what the package now emits

Delete from your resources the chain and immutability statements, the chain index,
the archive guard statements and its index, and the run ledger's anchor index. The
extension refuses to add a statement or an index whose name is already declared,
so a leftover one fails the compile rather than migrating twice.

Your `sequence`, partition, `previous_hash` and `hash` attributes may stay; the
extension adds only the ones you have not declared.

## 4. Generate the migration

Run `mix ash.codegen adopt_ash_events_chain`. With the names kept and the table
columns unchanged, the migration replaces the custom statements and nothing else:
it drops the old triggers and functions with the old statements' `down`, then
creates the new ones, in one transaction. Read it before you run it. The SQL text
differs from yours (comments, and each trigger statement carries a digest of its
function, so the two always migrate together), and that is all the diff should be.

## 5. Use the lock key generator

Set `advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator`. For a tenant
it gives the key AshEvents' default generator gives, so writers on the old and new
code take the same lock during a rolling deploy. It differs for an audited resource
without multitenancy whose events carry a partition in their metadata: the default
gives it a shared key no tenant-scoped writer takes, and this one gives it the
chain's.
