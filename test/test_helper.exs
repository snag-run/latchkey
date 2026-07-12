# Reset the Commanded EventStore to empty before each test run (issue #73).
#
# Unlike the Ecto read side, the EventStore is not wrapped in the SQL sandbox —
# Commanded runs its own Postgres connection — so streams and events persist
# across runs on the same partition DB and accumulate indefinitely. That backlog
# makes checkpointed ACL projections churn over the whole `$all` history, and lets
# a fresh run's unique-per-run stream ids (System.unique_integer resets each VM)
# collide with a prior run's persisted streams. The result: the *first* run on a
# fresh store passes, but every *repeat* local gate run flakes on a rotating cast
# of integration tests. CI never sees it because its Postgres is ephemeral (every
# CI run is a first run).
#
# Truncating once here — before ExUnit starts, and before any integration test
# boots Commanded via start_supervised!/1 — makes local == CI: every run begins
# on an empty store. The reset runs only under MIX_ENV=test (test_helper.exs is a
# test-only entrypoint), asserted below so it can never wipe a real store.
:test = Mix.env()

# Truncates streams/events/subscriptions/snapshots and re-seeds `$all`, mirroring
# EventStore.Tasks.Init's connect-and-run pattern. Requires the schema to exist,
# which `db.setup.quiet` (event_store.init) guarantees by running ahead of the
# test and precommit aliases.
event_store_config = EventStore.Config.parsed(Latchkey.EventStore, :latchkey)

{:ok, event_store_conn} =
  event_store_config
  |> EventStore.Config.default_postgrex_opts()
  |> Postgrex.start_link()

{:ok, _} = EventStore.Storage.Initializer.reset!(event_store_conn, event_store_config)

true = Process.unlink(event_store_conn)
true = Process.exit(event_store_conn, :shutdown)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Latchkey.Repo, :manual)
