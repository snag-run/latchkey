defmodule Latchkey.CommandedSupervisor do
  @moduledoc """
  Supervises the event-sourcing **write side** as one restartable subtree: the
  `CommandedApp` (which owns the EventStore connection pool and hosts the aggregate
  processes) and the three event handlers that subscribe to it — the `ArrearsProjector`,
  the payment ACL, and the inspector `Broadcaster`.

  Grouping them under a dedicated supervisor is what makes the simulation **reset
  primitive** possible (issue #173, ADR 0007 decision 3). A reset has to cold-start the
  whole write side: `Commanded.Aggregates.Aggregate` GenServers cache their folded state
  in memory (they even subscribe to their own stream on init), so wiping the store alone
  leaves a live aggregate still believing it is commenced — a reseed's `CommenceTenancy`
  then routes to that cached process and returns `:already_commenced` → a blank board.
  Restarting this subtree discards the cached aggregate state, and the handlers
  re-subscribe from their `start_from`, together giving a cleanly reseedable store.
  `Latchkey.Simulation.Reset` drives that restart; this module owns the tree it acts on.

  ## Ordering — `:rest_for_one`

  Children start in `CommandedApp` → handlers order: the handlers open subscriptions
  **to** the `CommandedApp`, so it must be up first. `:rest_for_one` mirrors that
  dependency at runtime — if the `CommandedApp` crashes, every handler started after it
  restarts too (their subscriptions died with it), while a single handler crashing never
  disturbs the app or its siblings.
  """
  use Supervisor

  @children [
    Latchkey.CommandedApp,
    Latchkey.PropertyManagement.ArrearsProjector,
    Latchkey.PropertyManagement.PaymentAcl,
    Latchkey.Inspector.Broadcaster
  ]

  @doc "Start the write-side supervision subtree, registered under the module name."
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Supervisor.init(@children, strategy: :rest_for_one)
  end

  @doc """
  The write-side child **modules** in **start order**. The reset primitive resolves each
  to its live supervisor child id (Commanded's handler ids are opaque `{module, opts}`
  tuples, not plain module names) and drives the tree by that: terminating in reverse of
  this order — handlers before the `CommandedApp` they subscribe to — and restarting in it.
  """
  @spec child_ids() :: [module()]
  def child_ids, do: @children
end
