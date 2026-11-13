<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Rules for working with AshEvents.Chain

## What it is

A hash chain over an `AshEvents.EventLog` table in Postgres, a verifier, and
retention to an archive. The chain and the immutability rules live in Postgres
triggers, emitted as AshPostgres custom statements. The package emits no policies.

## Setting up

- Put `AshEvents.Chain.Extension` in the event log's `extensions:` next to
  `AshEvents.EventLog`, then `use AshEvents.Chain.Resources, {:chained_log, opts}`
  after the `use Ash.Resource` line. `:partition` is required.
- Set `advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator` in the
  `event_log` block. Without it, two writers to one chain can both link to the same
  predecessor.
- With `partition_metadata_key:`, the trigger reads the partition from the event's
  metadata. Put it there on every audited write (for example a global change that
  sets `ash_events_metadata` context). An event without it joins the
  no-partition chain.
- Run `mix ash.codegen <name>` after adding or changing any of the macros' options.
  The statements are generated; never write the trigger SQL in a migration by hand.
- The archive and run ledger are separate resources:
  `{:archive, log:, table:, repo:}` and `{:archive_run, log:, table:, repo:}`. Give
  them your own policies. The run ledger's `:record` action is what retention calls,
  with the actor you pass.

## Verifying

- `AshEvents.Chain.verify(log, partition)` for one chain, `verify(log, nil)` for
  the no-partition chain, `verify_all(log)` for every chain. `findings: []` is clean.
- The verifier reads with raw SQL and no actor. Decide in your own code who may see
  its result.

## Retention

- `Retention.archive(log, actor: ...)` and `Retention.purge(log, purge_after_days:
  ..., actor: ...)`, or a worker defined with `use AshEvents.Chain.RetentionWorker`.
- `:hot_days` under 90 or `:purge_after_days` under 400 return
  `{:error, {:below_floor, option, floor}}`. The database triggers enforce the same
  floors.
- A chain with a finding is not moved. A move whose copy does not match deletes
  nothing and is recorded as a `:failed` run.
- Running retention twice is safe; the second run finds nothing to move.

## Don't

- Don't add create, update or destroy actions to the archive or the run ledger
  beyond `:record`.
- Don't change `digest_columns:` on a log that already has rows: existing hashes
  stop verifying. It exists to match the list existing rows were hashed over.
- Don't disable the triggers outside a test. The verifier will report what happens
  while they are off, but the triggers are what prevent it.
