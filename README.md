<!--
SPDX-FileCopyrightText: 2026 Luke Galea

SPDX-License-Identifier: MIT
-->

# AshEvents.Chain

A hash chain for an [AshEvents](https://hexdocs.pm/ash_events) event log in
Postgres, a verifier for it, and retention that moves old events to an archive
without breaking the chain.

- **The chain.** A `BEFORE INSERT` trigger links every event to the one before it
  in its chain (one chain per tenant, or per whatever column you choose) by storing
  the previous row's hash and the SHA-256 of its own columns. A second trigger
  refuses `UPDATE` and `DELETE` on the table.
- **The verifier.** `AshEvents.Chain.verify/2` recomputes every hash in SQL and
  reports rows that were altered, removed or inserted with the trigger disabled.
- **Retention.** `AshEvents.Chain.Retention` moves events past a hot window to an
  archive table: verify the chain, copy, compare the copy with the hot rows, then
  delete. Each step is recorded in a run ledger. The verifier reads the hot table
  and the archive as one chain, and continues across a purge from the hash the
  purge recorded.
- **Linear under concurrency.** AshEvents takes an advisory lock before each
  insert. `AshEvents.Chain.LockKeyGenerator` keys that lock on the chain, so writes
  to one chain are serialized and writes to different chains are not.

The package emits no policies. Its resource macros go onto your own resources,
after your own `use` line, so your base resource, domain, tenancy and policies
apply.

## Installation

```elixir
def deps do
  [
    {:ash_events_chain, "~> 0.1"}
  ]
end
```

It needs `ash_postgres` and Postgres 14 or later (`CREATE OR REPLACE TRIGGER`).
`AshEvents.Chain.RetentionWorker` needs `oban` in your application.

## The chained log

Add `AshEvents.Chain.Extension` to your event log and `use` the `:chained_log`
macro. Keep your own `postgres` block.

```elixir
defmodule MyApp.Audit.EventLog do
  use Ash.Resource,
    domain: MyApp.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.EventLog, AshEvents.Chain.Extension]

  use AshEvents.Chain.Resources,
      {:chained_log,
       partition: :organization_id,
       partition_metadata_key: "organization_id",
       archive_table: "audit_event_archive",
       archive_run: MyApp.Audit.ArchiveRun}

  postgres do
    table "audit_events"
    repo MyApp.Repo
  end

  event_log do
    persist_actor_primary_key :user_id, MyApp.Accounts.User
    advisory_lock_key_generator AshEvents.Chain.LockKeyGenerator
  end

  policies do
    # your read grant
  end
end
```

The extension adds `sequence`, the partition column, `previous_hash` and `hash`
(unless you declare them), an index on `[partition, sequence]`, and four custom
statements: the chain function and trigger, and the immutability function and
trigger. Run `mix ash.codegen` to generate the migration.

With `partition_metadata_key:`, the trigger takes the partition from the event's
metadata, so set it there on every audited write, for example in a global change
that puts the tenant into `ash_events_metadata` context.

## Archive and run ledger

```elixir
defmodule MyApp.Audit.ArchivedEvent do
  use Ash.Resource,
    domain: MyApp.Audit,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  use AshEvents.Chain.Resources,
      {:archive, log: MyApp.Audit.EventLog, table: "audit_event_archive", repo: MyApp.Repo}

  policies do
    # your read grant
  end
end

defmodule MyApp.Audit.ArchiveRun do
  use MyApp.Platform.Resource, domain: MyApp.Audit

  use AshEvents.Chain.Resources,
      {:archive_run,
       log: MyApp.Audit.EventLog,
       table: "audit_archive_runs",
       repo: MyApp.Repo,
       chain_attribute: :chain_organization_id}

  policies do
    # who may record a retention step, and who may read them
  end
end
```

The archive has the log's columns with the log's types, plus `archived_at`, and no
write actions. Its trigger refuses every `UPDATE`, and a `DELETE` of a row younger
than 400 days. The hot table's trigger allows one `DELETE`: a row older than 90
days with an identical copy already in the archive.

## Verifying

```elixir
AshEvents.Chain.verify(MyApp.Audit.EventLog, organization_id)
#=> %{partition: "…", anchored_after: nil, checked: 1204,
#     skipped_unchained_prefix: 0, findings: []}

MyApp.Audit.EventLog |> AshEvents.Chain.verify_all() |> AshEvents.Chain.clean?()
#=> true
```

A finding is `%{sequence:, id:, occurred_at:, problem:}`, where `problem` is
`:altered`, `:broken_link` or `:unchained`.

## Retention

```elixir
AshEvents.Chain.Retention.archive(MyApp.Audit.EventLog, actor: system_actor)
AshEvents.Chain.Retention.purge(MyApp.Audit.EventLog, purge_after_days: 2555, actor: system_actor)
```

Or define a worker and put it on your Oban cron:

```elixir
defmodule MyApp.Audit.RetentionWorker do
  use AshEvents.Chain.RetentionWorker,
    log: MyApp.Audit.EventLog,
    otp_app: :my_app,
    actor: {MyApp.SystemActor, :retention, []}
end
```

`:hot_days` cannot be under 90 and `:purge_after_days` cannot be under 400. Purge
never runs unless `:purge_after_days` is set.

## An existing chain

A host that already has a hash-chained log can adopt the package without
rehashing: keep the table, statement and function names, and pass the column list
its rows were hashed over as `digest_columns:`. See
[Adopting an existing chain](documentation/topics/adopting-an-existing-chain.md).

## Licence

MIT. See the `LICENSE` file.
