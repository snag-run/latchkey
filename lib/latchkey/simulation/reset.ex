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

  ## Two wipes: the coarse primitive (#173) and the allowlist-scoped reset (#174)

  `reset_event_store!/0` (the #173 primitive) truncates the **whole** event-store schema.
  That is acceptable *for the primitive* because the schema holds only simulation data —
  durable application data (users/auth) lives in the Ecto `Repo` and is never touched.

  `reset_to_healthy!/1` (the #174 reset-to-healthy) is the production reset the monthly
  cron drives. It **narrows** the wipe to an allowlist — `tenancy-*` streams + the Accounts
  stream — and **reseeds** a fresh board, so it can regenerate the demo without a blanket
  store drop (ADR 0007 decision 3):

    1. **Advance the seed generation first** (`SeedGeneration.advance/0`), *before* any
       purge/replan (issue #162), so a job Oban has already *claimed* under the old
       generation no-ops instead of dispatching stale work into the fresh seed.
    2. **Wipe only the allowlist** — hard-delete every `tenancy-*` stream and the Accounts
       stream, truncate only the projections derived from them (`Arrears`; the `Directory`
       identity fixture). A stream that is neither a `tenancy-*` nor the Accounts stream is
       **never touched** (`simulation_stream?/2` is that boundary); the seed-generation
       counter, Oban's tables, and any users/auth are not in the truncate list.
    3. **Clear the subscription checkpoints.** This is the subtle half. The coarse
       primitive gets subscription-clearing *for free* from the whole-schema truncate; a
       narrowed per-stream delete does not, so a cold-restarted handler would otherwise
       resume from a stale checkpoint over the wiped store and never rebuild. We therefore
       delete the handlers' checkpoints explicitly (they are all simulation-owned Commanded
       bookkeeping), so the restarted `ArrearsProjector` / payment ACL re-subscribe from
       `:origin` and refold the reseeded streams from scratch.
    4. **Restart the subtree, then reseed + replan** — `Seeder.seed/1` then `Planner.plan/1`
       against a board that is a pure function of `today`.

  ## Idempotent under retry

  Both entry points are a full terminate → wipe → restart (and, for `reset_to_healthy!/1`,
  reseed), so running either twice leaves the same cleanly reseedable/reseeded store — a
  reset that dies partway is recovered by simply running it again (ADR 0007 decision 3:
  recovery is re-run, not repair). Hard-deleting an already-gone stream is tolerated, and a
  truncate/reseed over a fresh store is a no-op-then-rebuild.

  This means a reset that dies **after the wipe but before the reseed finishes** leaves the
  board momentarily **empty**, not half-repaired — an intentional consequence of re-run-not-
  repair, and safe because the board is a pure function of `today`: the retried run (a fresh
  Oban attempt, `max_attempts: 3`) rebuilds it whole. An empty demo board is a self-healing
  transient, never a state anyone hand-mends.

  > ### Neon `-pooler` gotcha
  > The transient wipe connection (and any later `consistency: :strong` reseed dispatch)
  > must use the **direct**, non-pooler EventStore endpoint. A PgBouncer (`-pooler`) URL
  > cannot hold the EventStore's `LISTEN`/`NOTIFY`, so projectors never ack and every
  > strong dispatch times out. Local worktree Docker Postgres is fine.
  """

  alias Latchkey.CommandedSupervisor
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.Repo
  alias Latchkey.Simulation.Directory
  alias Latchkey.Simulation.Planner
  alias Latchkey.Simulation.Seeder
  alias Latchkey.Simulation.SeedGeneration

  @supervisor CommandedSupervisor

  # The Accounts stream the reset allowlist targets when no override is given. The seeder
  # keys real payments to this stream; tests pass a unique one through `:accounts_stream`.
  @default_accounts_stream "accounts"

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
    with_write_side_down(&truncate_store!/0)
    :ok
  end

  @doc """
  Reset the demo store **to a fresh healthy board** — the allowlist-scoped, reseeding reset
  the monthly cron drives (issue #174, ADR 0007 decision 3).

  Advances the seed generation first (so an already-claimed old-generation job no-ops —
  issue #162), hard-deletes only the `tenancy-*` streams + the Accounts stream and truncates
  only their projections (`Arrears`, `Directory`) while the write side is down, clears the
  handlers' subscription checkpoints so they rebuild from `:origin`, then restarts the
  subtree and reseeds + replans a board that is a pure function of `today`. Durable
  non-simulation data (users/auth, the seed-generation counter, Oban) is never in the wipe.
  Idempotent under retry. Returns `:ok`.

  Options are forwarded to `Seeder.seed/1` and `Planner.plan/1` (`:today`, `:scenarios`,
  `:id_prefix`, `:accounts_stream`, …); `:accounts_stream` also names the Accounts stream
  the allowlist deletes (defaults to `#{@default_accounts_stream}`).
  """
  @spec reset_to_healthy!(keyword()) :: :ok
  def reset_to_healthy!(opts \\ []) do
    # Validate the destructive target FIRST, before any mutation (before even advancing the
    # generation): the Accounts stream is a caller-supplied hard-delete target, and it must
    # be an Accounts stream — never a durable/non-simulation name (issue #174 hardening).
    accounts_stream = Keyword.get(opts, :accounts_stream, @default_accounts_stream)
    validate_accounts_stream!(accounts_stream)

    # Generation-safe (issue #162): advance BEFORE the purge/replan, so any job Oban has
    # already claimed under the old generation is left stale and no-ops on dispatch.
    _new_generation = SeedGeneration.advance()

    with_write_side_down(fn -> wipe_simulation_data!(accounts_stream) end)

    # Re-run, not repair: rebuild the board from the seed (a pure function of `today`).
    _seeded = Seeder.seed(opts)
    _planned = Planner.plan(opts)

    :ok
  end

  # Terminate the write-side subtree in reverse start order (discarding every cached
  # aggregate process), run `wipe_fun` over the down store, then restart every child in
  # start order so the handlers re-subscribe from their `start_from` and rebuild.
  #
  # Fault-tolerant on both halves, so one failure can never strand the rest of the subtree
  # down (the write side comes back **up** — operational, not stranded DOWN — whatever fails):
  #
  #   * teardown + wipe run under `attempt/1`, so if a `terminate!/1` (or the wipe) raises
  #     partway, the restart pass still runs and brings the already-stopped children back;
  #   * the restart pass attempts **every** child even if an individual `restart!/1` raises,
  #     rather than aborting on the first failure.
  #
  # The first error is re-raised only *after* every restart has been attempted, with teardown/
  # wipe taking precedence over a restart failure (it is the root cause, and it comes first).
  # That is the "re-run, not repair" contract: a reset that dies partway is recovered by
  # re-running.
  defp with_write_side_down(wipe_fun) do
    ids = ordered_child_ids()

    teardown =
      attempt(fn ->
        Enum.each(Enum.reverse(ids), &terminate!/1)
        wipe_fun.()
      end)

    restart = ids |> Enum.map(fn id -> attempt(fn -> restart!(id) end) end) |> first_error()

    reraise_first!([teardown, restart])
  end

  # Run `fun`, returning `:ok` or `{:error, {exception, stacktrace}}` instead of raising — so
  # callers can attempt every step and decide which error to surface once all have run.
  defp attempt(fun) do
    fun.()
    :ok
  rescue
    error -> {:error, {error, __STACKTRACE__}}
  end

  defp first_error(results), do: Enum.find(results, :ok, &match?({:error, _}, &1))

  defp reraise_first!(results) do
    case first_error(results) do
      :ok -> :ok
      {:error, {error, stacktrace}} -> reraise(error, stacktrace)
    end
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
  # store connection) is down, so nothing contends. The connection is unlinked **immediately**
  # (before the wipe) so an abnormal conn exit mid-wipe can never kill the caller before the
  # `after` cleanup runs.
  defp truncate_store! do
    config = EventStore.Config.parsed(Latchkey.EventStore, :latchkey)

    {:ok, conn} =
      config
      |> EventStore.Config.default_postgrex_opts()
      |> Postgrex.start_link()

    true = Process.unlink(conn)

    try do
      {:ok, _} = EventStore.Storage.Initializer.reset!(conn, config)
    after
      true = Process.exit(conn, :shutdown)
    end

    :ok
  end

  @doc """
  The allowlist boundary (issue #174): a stream is simulation-owned — and so in scope for
  the reset's deletion — iff it is a `tenancy-*` aggregate stream or **the** Accounts stream.
  Everything else is preserved. This is the primary safety boundary of the destructive
  reset: it can regenerate the board without ever being able to touch data it did not seed.
  """
  @spec simulation_stream?(String.t(), String.t()) :: boolean()
  def simulation_stream?(stream_uuid, accounts_stream) do
    String.starts_with?(stream_uuid, "tenancy-") or stream_uuid == accounts_stream
  end

  # Guard the one caller-supplied hard-delete target. `tenancy-*` is a fixed prefix, but the
  # Accounts stream name is an option, so constrain it to an Accounts stream — the fixed
  # production `"accounts"` or a test-prefixed `"accounts-*"` — so a caller can never aim the
  # destructive wipe at a durable/non-simulation stream (e.g. `"users"`). Raises before any
  # mutation; the production `ResetWorker` never forwards this, so it always hits the default.
  defp validate_accounts_stream!(@default_accounts_stream), do: :ok

  defp validate_accounts_stream!(accounts_stream) when is_binary(accounts_stream) do
    if String.starts_with?(accounts_stream, @default_accounts_stream <> "-") do
      :ok
    else
      raise ArgumentError,
            "reset_to_healthy!/1 refuses to hard-delete #{inspect(accounts_stream)} as the " <>
              "Accounts stream: expected #{inspect(@default_accounts_stream)} or an " <>
              "#{inspect(@default_accounts_stream <> "-")}… stream, never a non-simulation name."
    end
  end

  # Wipe only the simulation-owned data (issue #174), run while the write side is down:
  # hard-delete the allowlisted event streams + clear the handlers' subscription
  # checkpoints (over a transient store connection), then truncate the projections derived
  # from those streams (over the always-up main `Repo`). Durable non-simulation data is
  # never in either step.
  defp wipe_simulation_data!(accounts_stream) do
    delete_simulation_streams!(accounts_stream)
    truncate_projections!()
    :ok
  end

  # Over a transient Postgrex connection (the write-side pool is down, so nothing contends),
  # hard-delete every allowlisted stream and then delete the subscription checkpoints. The
  # checkpoint clear is the narrowed reset's equivalent of the coarse primitive's
  # subscription truncate — without it a cold-restarted handler would resume mid-`$all` over
  # the wiped store and never rebuild (see moduledoc). All subscriptions are the simulation
  # handlers' own Commanded bookkeeping. The connection is unlinked **immediately** (before
  # the wipe) so an abnormal conn exit mid-wipe can never kill the caller before cleanup runs.
  defp delete_simulation_streams!(accounts_stream) do
    config = EventStore.Config.parsed(Latchkey.EventStore, :latchkey)
    schema = Keyword.get(config, :schema, "public")

    {:ok, conn} =
      config
      |> EventStore.Config.default_postgrex_opts()
      |> Postgrex.start_link()

    true = Process.unlink(conn)

    try do
      # Run the whole wipe in one transaction so the session setting and the deletes share a
      # single pinned connection. EventStore guards its tables with a trigger that blocks
      # DELETE unless `eventstore.enable_hard_deletes` is on for the session issuing it — so
      # enabling it on a *different* pooled connection than the delete would not help. Scoped
      # to this transient connection only: no schema migration, no global config change.
      {:ok, :ok} =
        Postgrex.transaction(
          conn,
          fn tx ->
            {:ok, _} =
              Postgrex.query(tx, "SET SESSION eventstore.enable_hard_deletes TO 'on';", [])

            tx
            |> allowlisted_stream_ids(schema, accounts_stream)
            |> Enum.each(&hard_delete_stream!(tx, &1, schema))

            clear_subscription_checkpoints!(tx, schema)
          end,
          timeout: :infinity
        )
    after
      true = Process.exit(conn, :shutdown)
    end

    :ok
  end

  # The `stream_id`s of every allowlisted stream in the store. Enumerates all streams
  # (`$all` and any non-simulation stream are filtered out by `simulation_stream?/2`) and
  # keeps only the ones the allowlist owns.
  defp allowlisted_stream_ids(conn, schema, accounts_stream) do
    conn
    |> all_streams(schema)
    |> Enum.filter(&simulation_stream?(&1.stream_uuid, accounts_stream))
    |> Enum.map(& &1.stream_id)
  end

  # Page through every stream in the store (~100 tenancies + the Accounts stream at demo
  # scale). Accumulates entries until the last page, so the enumeration is complete.
  defp all_streams(conn, schema) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while([], fn page_number, acc ->
      {:ok, %EventStore.Page{entries: entries, total_pages: total_pages}} =
        EventStore.Storage.paginate_streams(conn,
          page_number: page_number,
          page_size: 100,
          schema: schema
        )

      acc = acc ++ entries

      if page_number >= max(total_pages, 1), do: {:halt, acc}, else: {:cont, acc}
    end)
  end

  # Hard-delete a stream by id — removes its events (and their `$all` links). Tolerates an
  # already-gone stream so the reset stays idempotent under retry.
  defp hard_delete_stream!(conn, stream_id, schema) do
    case EventStore.Storage.hard_delete_stream(conn, stream_id, schema: schema) do
      :ok -> :ok
      {:error, :stream_not_found} -> :ok
    end
  end

  # Delete the handlers' subscription checkpoints so the cold-restarted handlers re-subscribe
  # from their `start_from` (`:origin` for the projector/ACL) and refold the reseeded store.
  #
  # Enforced, not assumed: every checkpoint found must belong to a known write-side handler
  # (the `CommandedSupervisor` children — Commanded stores each subscription under
  # `inspect(handler_module)`). An unexpected subscriber makes the reset **raise loudly**
  # rather than silently clobber a checkpoint it does not own — the store is ES-dedicated
  # (ADR 0003), so a foreign subscription would be a real surprise worth stopping on.
  defp clear_subscription_checkpoints!(conn, schema) do
    {:ok, subscriptions} = EventStore.Storage.subscriptions(conn, schema: schema)
    known = MapSet.new(CommandedSupervisor.child_ids(), &inspect/1)

    Enum.each(subscriptions, fn %{stream_uuid: stream_uuid, subscription_name: name} ->
      if MapSet.member?(known, name) do
        :ok = EventStore.Storage.delete_subscription(conn, stream_uuid, name, schema: schema)
      else
        raise "Reset refusing to clear an unrecognised subscription #{inspect(name)} on " <>
                "#{inspect(stream_uuid)}: not a known write-side handler " <>
                "(#{inspect(Enum.sort(MapSet.to_list(known)))}). The simulation store is " <>
                "event-sourcing-dedicated (ADR 0003), so a foreign subscriber is unexpected."
      end
    end)

    :ok
  end

  # Truncate only the projections derived from the simulation streams: `Arrears` (the
  # event-sourced read model the projector rebuilds from `:origin`) and the `Directory`
  # identity fixture (repopulated by the reseed). Everything else in the `Repo` — the
  # seed-generation counter, Oban's tables, any users/auth — is deliberately left alone.
  #
  # sobelow_skip ["SQL.Query"]
  defp truncate_projections! do
    # The interpolated identifiers are the resources' own table names (trusted DSL, not user
    # input) — read from the resource so a rename can never silently desync the truncate.
    Repo.query!(~s{TRUNCATE TABLE "#{table(Arrears)}", "#{table(Directory)}"})
    :ok
  end

  # The Postgres table backing an Ash resource — read from the resource itself so a table
  # rename can never silently desync the truncate list.
  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)
end
