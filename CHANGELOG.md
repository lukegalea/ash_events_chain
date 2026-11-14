<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Change Log

## Unreleased

### Bug Fixes

- `AshEvents.Chain.Retention.archive/2`: a chain whose verification raises is recorded
  as a `:failed` run with the error as its reason, and every other chain is still
  archived. Before, the exception stopped the whole call.
- `AshEvents.Chain.verify_all/2` with `on_error: :return` verifies every chain even when
  one raises, returning that chain's result with `error:` set. `clean?/1` is false for
  such a result. The default, `:raise`, is unchanged.

### Features

- Retention drains a backlog within a bound: `:max_batches` (default 1, as before) and
  `:deadline_ms`. The last step of each chain carries what is still eligible as `backlog`
  in its run's metadata (`Retention.backlog/1`), a verified run that leaves a backlog
  says so in its `reason`, and each chain emits a
  `[:ash_events_chain, :retention, :chain]` telemetry event. `RetentionWorker.run/2`
  returns the backlog.
- `AshEvents.Chain.verify_isolated/3`, verifying one chain and returning a raised
  verification as `{:error, message}`.

- `AshEvents.Chain.Resources` macros a host puts on its own resources:
  `{:chained_log, opts}` on an `AshEvents.EventLog` resource, `{:archive, opts}` for
  the archive table and `{:archive_run, opts}` for the run ledger.
- A per-partition hash chain kept by a Postgres trigger, and an immutability
  trigger that refuses `UPDATE` and `DELETE` except retention's verified move.
- `digest_columns:`, the column list the hash covers, for a host whose existing
  rows were hashed over a different list.
- `AshEvents.Chain.verify/2` and `verify_all/1`, reading the hot table and the
  archive as one chain and continuing across a purge.
- `AshEvents.Chain.Retention`: archive past a hot window (at least 90 days) with a
  verified copy, purge past a configured age (at least 400 days), each step
  recorded in the run ledger.
- `AshEvents.Chain.RetentionWorker`, an Oban worker a host defines and schedules.
- `AshEvents.Chain.LockKeyGenerator`, keying AshEvents' advisory lock on the chain.
