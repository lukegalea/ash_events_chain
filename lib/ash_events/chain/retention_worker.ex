# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Chain.RetentionWorker do
  @moduledoc """
  Defines an Oban worker that runs retention for one chained log: `archive/2`, then
  `purge/2` (`AshEvents.Chain.Retention`).

      defmodule MyApp.Audit.RetentionWorker do
        use AshEvents.Chain.RetentionWorker,
          log: MyApp.Audit.EventLog,
          otp_app: :my_app,
          actor: {MyApp.SystemActor, :retention, []}
      end

  The host puts it on its Oban cron:

      config :my_app, Oban,
        plugins: [{Oban.Plugins.Cron, crontab: [{"30 3 * * *", MyApp.Audit.RetentionWorker}]}]

  and sets the retention options under the worker's own key, read when each job runs:

      config :my_app, MyApp.Audit.RetentionWorker,
        hot_days: 90,
        purge_after_days: nil,
        batch_size: 10_000

  ## Options

    * `:log` - **required**. The chained log.
    * `:otp_app` - the application whose environment holds the retention options.
    * `:actor` - the actor the run ledger's `:record` runs as: a value, or
      `{module, function, args}` called when the job runs.
    * `:oban` - options for `use Oban.Worker`. Default
      `[queue: :default, max_attempts: 3, unique: [period: 3600]]`.
    * any `AshEvents.Chain.Retention` option, as a default the environment overrides.

  Idempotent: a second run the same day finds nothing to move. A move that does not
  verify deletes nothing and is recorded as a failed run; the job still succeeds,
  because retrying a move that refused would refuse again, and the failed run is the
  record someone reads.
  """

  alias AshEvents.Chain.Retention

  @default_oban [queue: :default, max_attempts: 3, unique: [period: 3600]]

  defmacro __using__(opts) do
    {log, opts} = Keyword.pop(opts, :log)
    {otp_app, opts} = Keyword.pop(opts, :otp_app)
    {oban, opts} = Keyword.pop(opts, :oban, @default_oban)

    if is_nil(log), do: raise(ArgumentError, "use AshEvents.Chain.RetentionWorker needs :log")

    env =
      if otp_app,
        do: quote(do: Application.get_env(unquote(otp_app), __MODULE__, [])),
        else: []

    quote location: :keep do
      use Oban.Worker, unquote(oban)

      @impl Oban.Worker
      def perform(%Oban.Job{}) do
        AshEvents.Chain.RetentionWorker.run(unquote(log), retention_opts())
      end

      @doc "The retention options a job runs with: the `use` options, then the environment."
      def retention_opts do
        Keyword.merge(unquote(opts), unquote(env))
      end
    end
  end

  @doc """
  Archives, then purges, `log` with `opts`. Returns `{:ok, %{archived: counts, purged:
  counts}}`, where `counts` are the steps by kind, or `{:error, reason}`.
  """
  @spec run(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(log, opts) do
    opts = Keyword.update(opts, :actor, nil, &resolve_actor/1)

    with {:ok, archived} <- Retention.archive(log, opts),
         {:ok, purged} <- Retention.purge(log, opts) do
      {:ok, %{archived: summary(archived), purged: summary(purged)}}
    end
  end

  defp resolve_actor({module, function, args}) when is_atom(module) and is_atom(function),
    do: apply(module, function, args)

  defp resolve_actor(actor), do: actor

  defp summary(:disabled), do: :disabled
  defp summary(steps), do: Enum.frequencies_by(steps, &step/1)

  defp step({kind, _run}), do: kind
  defp step(kind), do: kind
end
