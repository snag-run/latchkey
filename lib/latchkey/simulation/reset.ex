defmodule Latchkey.Simulation.Reset do
  @moduledoc """
  The **Commanded reset primitive** — cold-starts the event-sourcing write side so the
  simulation store is cleanly reseedable (issue #173, ADR 0007 decision 3). This is the
  spike-first half of periodic reset-to-healthy; the guarded, allowlist-scoped destructive
  cron (#174) rides on top of this primitive.

  ## The problem this solves

  A naive "delete the simulation streams → truncate the read models → reseed" **does not
  work**. `Commanded.Aggregates.Aggregate` processes cache their folded state in memory
  (`deps/commanded/lib/commanded/aggregates/aggregate.ex` — an aggregate even subscribes
  to its own stream on init), so deleting `tenancy-<id>` from the store does not evict the
  live process. A reseed's `CommenceTenancy` still routes to that cached aggregate, which
  answers `{:error, :already_commenced}` from memory before ever touching the store → a
  blank board. The reset must therefore drive Commanded's **aggregate lifecycle**, not
  just the store's rows.

  ## The chosen primitive — restart the `CommandedApp` subtree

  Two designs were on the table (this was a spike):

    1. **Stop the cached aggregate processes one by one** —
       `Commanded.Aggregates.Aggregate.shutdown/3` is `@doc false` (a private API), needs
       enumerating every live aggregate uuid, and does nothing about subscription
       checkpoints. Fragile, and only half the job.
    2. **Restart the whole `CommandedApp` subtree** — a single cold start clears *all*
       cached aggregate state at once and re-establishes every subscription together.

  Option 2 is the primitive. `Latchkey.CommandedSupervisor` groups the write side
  (`CommandedApp` + the three event handlers) into one subtree; `reset_event_store!/0`
  tears it down, truncates the store, and brings it back up.

  ## Subscription checkpoints — the subtle half

  The event handlers persist their position in the store's `subscriptions` table.
  `start_from:` (`:origin` for the `ArrearsProjector` and payment ACL, `:current` for the
  inspector `Broadcaster`) is honoured **only on the first subscription** — a lingering
  checkpoint row would otherwise make a cold-restarted handler resume mid-stream over a
  freshly wiped store and never rebuild. Truncating the store therefore has to clear the
  `subscriptions` rows too, so the restarted handlers re-subscribe from their `start_from`
  and rebuild the read models from origin. `EventStore.Storage.Initializer.reset!/2`
  truncates events, streams, subscriptions and snapshots in one transaction — exactly the
  atomic wipe the checkpoints need (it is the same call `test/test_helper.exs` uses).

  ## Ordering and connection ownership

  The subtree is torn down in **reverse start order** (handlers before the `CommandedApp`
  they subscribe to) and brought back in start order. The store is truncated **while the
  subtree is down**: the EventStore connection pool is a child of the `CommandedApp`, so
  the wipe runs over a transient `Postgrex` connection with no live pool contending — the
  same connect-wipe-disconnect dance as `test/test_helper.exs`.

  ## Scope and coarseness (deliberate, for #173)

  This truncates the **whole** event-store schema, which is acceptable here because that
  schema holds only simulation data — durable application data (users/auth) lives in the
  Ecto `Repo` and is never touched. #174 narrows the wipe to a `tenancy-*` / accounts
  **allowlist** and wraps it in the config guard + Oban cron; this ticket proves the
  aggregate-lifecycle + subscription primitive underneath.

  ## Idempotent under retry

  `reset_event_store!/0` is a full terminate → wipe → restart, so running it twice leaves
  the same cleanly reseedable store — a reset that dies partway is recovered by simply
  running it again (ADR 0007 decision 3: recovery is re-run, not repair).

  > ### Neon `-pooler` gotcha
  > The transient wipe connection (and any later `consistency: :strong` reseed dispatch)
  > must use the **direct**, non-pooler EventStore endpoint. A PgBouncer (`-pooler`) URL
  > cannot hold the EventStore's `LISTEN`/`NOTIFY`, so projectors never ack and every
  > strong dispatch times out. Local worktree Docker Postgres is fine.
  """

  alias Latchkey.CommandedSupervisor

  @supervisor CommandedSupervisor

  @doc """
  Cold-start the write side so the store is cleanly reseedable.

  Terminates the `CommandedSupervisor` subtree in reverse start order (discarding every
  cached aggregate process), truncates the event store — events, streams, subscription
  checkpoints and snapshots — over a transient connection, then restarts the subtree in
  start order so the handlers re-subscribe from their `start_from` and rebuild. Idempotent
  under retry. Returns `:ok`.
  """
  @spec reset_event_store!() :: :ok
  def reset_event_store! do
    ids = ordered_child_ids()

    Enum.each(Enum.reverse(ids), &terminate!/1)
    truncate_store!()
    Enum.each(ids, &restart!/1)

    :ok
  end

  # The live supervisor's child **ids** in start order. Commanded builds opaque ids — a
  # `CommandedApp` uses its module name, but an event handler's is a `{module, opts}`
  # tuple — so we resolve them from the running tree (`which_children/1` carries each
  # child's callback module) rather than guessing, then order by the supervisor's
  # declared start order.
  defp ordered_child_ids do
    id_by_module =
      for {id, _pid, _type, modules} <- Supervisor.which_children(@supervisor),
          module <- List.wrap(modules),
          into: %{},
          do: {module, id}

    Enum.map(CommandedSupervisor.child_ids(), &Map.fetch!(id_by_module, &1))
  end

  # Stop a child, tolerating one already stopped so the primitive stays idempotent.
  defp terminate!(child_id) do
    case Supervisor.terminate_child(@supervisor, child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  # Restart a stopped child, tolerating one already running (a half-completed prior reset).
  defp restart!(child_id) do
    case Supervisor.restart_child(@supervisor, child_id) do
      {:ok, _child} -> :ok
      {:ok, _child, _info} -> :ok
      {:error, :running} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  # Truncate events/streams/subscriptions/snapshots over a transient Postgrex connection,
  # mirroring `test/test_helper.exs`. Runs while the write-side subtree (and its pooled
  # store connection) is down, so nothing contends. The connection is unlinked before it
  # is shut down so a wipe failure can never take the caller down with it.
  defp truncate_store! do
    config = EventStore.Config.parsed(Latchkey.EventStore, :latchkey)

    {:ok, conn} =
      config
      |> EventStore.Config.default_postgrex_opts()
      |> Postgrex.start_link()

    try do
      {:ok, _} = EventStore.Storage.Initializer.reset!(conn, config)
    after
      true = Process.unlink(conn)
      true = Process.exit(conn, :shutdown)
    end

    :ok
  end
end
