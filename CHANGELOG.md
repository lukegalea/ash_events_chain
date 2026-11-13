<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# Change Log

## Unreleased

### Features

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
