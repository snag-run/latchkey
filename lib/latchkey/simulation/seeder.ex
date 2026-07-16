defmodule Latchkey.Simulation.Seeder do
  @moduledoc """
  Seeds a **scenario catalogue** at demo scale — a ~100-tenancy board in interesting,
  legible arrears/exit states, each engineered to sit at a chosen state **today**
  (ADR 0005 decision 9 / ADR 0007). This is what makes the app interactive on load:
  you walk into a full board of tenancies and play the agent.

  The catalogue itself (`catalogue/1`, pure) lives in
  `Latchkey.Simulation.Seeder.Catalogue`; its per-scenario ordering and derived
  `:expected` come from `Latchkey.Simulation.Seeder.Projection`. This module owns the
  **impure** seam — replaying each scenario through the live command → read-model path.

  ## Replays the live loop, never a bulk-append path

  Backhistory is manufactured by replaying the **same** functions the live loop runs,
  parameterised with historical dates (ADR 0005 decision 9):

    * the tenant **behaviour engine** produces the `PaymentReceived` facts, appended to
      the **Accounts** stream and crossing **ACL-1** exactly as a live payment does;
    * the simulated agent's **notice** / **keys-return** — **derived** from the
      world-line's `≤ today` slice (ADR 0011), not hand-planted — are dispatched as the
      real `GiveTerminationNotice` / `ReturnKeys` commands; and
    * the **sweep** (`Sweep` `CatchUp`) books the owed `RentFellDue`s for non-payers,
      revealing their arrears.

  So seeded output is identical to live in decision path + ledger outcomes, modulo the
  deliberately-divergent seeder-assigned `recorded_on`.

  ## Fresh-store seed, not a resumable checkpoint

  This is a **dev/demo** seed targeting a **fresh store** (`mix ecto.reset && mix run
  priv/repo/seeds.exs`). A re-seed against an already-seeded store detects the
  commenced tenancy and returns `:skipped` **without** re-running — a guard against
  double-seeding a healthy board, **not** a resumable checkpoint. Recovery from a
  failed seed is drop-and-recreate, not in-place repair.

  ## Interleave, await, then reveal

  Seeding runs in three passes:

    1. **Commence** every tenancy (concurrent, bounded by `:max_concurrency`) and fill
       its `Directory` identity, capturing each scenario's dated timeline.
    2. **Replay** every tenancy's payments / notice / keys-return in a **single
       chronological pass** — the per-tenancy timelines merged and ordered by each
       step's real-world date — so the shared Accounts stream **interleaves** tenancies
       the way a live payments book arrives (issue #115), rather than clustered per
       tenancy. The merge is a total, stable order — `{date, tenancy_id, intra-stream
       position}` — so a reseed reproduces the same interleaving (ADR 0005) and no
       tenancy's own stream ever reorders (its steps share a `tenancy_id` and keep their
       timeline sequence).
    3. **Reveal** arrears: sweep each tenancy (concurrent) as of today.

  Payments cross ACL-1 **asynchronously**, so the replay subscribes to each tenancy
  stream (filtered to `RentPaymentRecorded`) and, after appending each payment, waits
  for that booking before advancing — guaranteeing a later planted notice (or the
  closing sweep) folds over the payments that precede it. The pass is sequential with
  one payment in flight at a time, so awaiting every payment leaves all bookings applied
  before any sweep runs. The closing `CatchUp` (as of today) is dispatched with
  `consistency: :strong`, so on return the `Arrears` read model reflects the whole
  catalogue.
  """

  require Logger

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Clock
  alias Latchkey.CommandedApp
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Sweep
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy
  alias Latchkey.PropertyManagement.Tenancy.Commands.GiveTerminationNotice
  alias Latchkey.PropertyManagement.Tenancy.Commands.ReturnKeys
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.Simulation.Directory
  alias Latchkey.Simulation.Identity
  alias Latchkey.Simulation.Seeder.Catalogue
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario

  @default_await_ms 5_000
  @default_max_concurrency 10

  # ── the catalogue (pure) ──────────────────────────────────────────────────────

  @doc """
  The scenario catalogue as a pure function of `today` (defaults to the live Sydney
  date). Every date is an offset from `today`, so each tenancy lands at its intended
  state *as of that day* regardless of when the seed runs.
  """
  @spec catalogue(Date.t()) :: [Scenario.t()]
  def catalogue(today \\ Clock.today()), do: Catalogue.build(today)

  # ── seeding (impure — dispatches through the live seam) ───────────────────────

  @doc """
  Seed the catalogue through the live command → read-model seam. Returns one result
  map per scenario: `%{scenario, tenancy_id, status}` where `status` is `:seeded` or
  `:skipped` (already commenced).

  Options:

    * `:today` — the reference date (defaults to `Clock.today/0`).
    * `:scenarios` — the scenarios to seed (defaults to the full `catalogue/1`); tests
      pass a small representative subset.
    * `:id_prefix` — prepended to each `tenancy_id` for stream isolation (tests pass a
      unique prefix; the real seed leaves it `""` for stable, legible ids).
    * `:accounts_stream` — the Accounts stream payments are appended to (defaults to
      `"accounts"`; tests key it uniquely).
    * `:await_ms` — per-payment await timeout (defaults to `#{@default_await_ms}`).
    * `:max_concurrency` — how many scenarios seed at once (defaults to
      `#{@default_max_concurrency}`).
  """
  @spec seed(keyword()) :: [%{scenario: Scenario.t(), tenancy_id: String.t(), status: atom()}]
  def seed(opts \\ []) do
    today = Keyword.get(opts, :today, Clock.today())
    scenarios = Keyword.get_lazy(opts, :scenarios, fn -> catalogue(today) end)
    prefix = Keyword.get(opts, :id_prefix, "")
    accounts_stream = Keyword.get(opts, :accounts_stream, "accounts")
    await_ms = Keyword.get(opts, :await_ms, @default_await_ms)
    max_concurrency = Keyword.get(opts, :max_concurrency, @default_max_concurrency)

    contexts = commence_all(scenarios, prefix, today, max_concurrency)
    replay_interleaved(contexts, accounts_stream, await_ms)
    reveal_arrears(contexts, today, max_concurrency)

    Enum.map(contexts, &Map.take(&1, [:scenario, :tenancy_id, :status]))
  end

  # ── pass 1: commence + identity (concurrent) ──────────────────────────────────

  # Commence every tenancy and fill its Directory identity, capturing the scenario's
  # dated timeline (the world-line's `≤ today` slice) for the interleaved replay.
  # Independent per tenancy, so concurrent.
  defp commence_all(scenarios, prefix, today, max_concurrency) do
    scenarios
    |> Task.async_stream(&commence_scenario(&1, prefix, today),
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, context} -> context end)
  end

  defp commence_scenario(%Scenario{} = scenario, prefix, today) do
    tenancy_id = prefix <> scenario.tenancy_id

    {status, steps} =
      case commence(scenario, tenancy_id) do
        :ok ->
          {:seeded, Projection.dated_timeline(scenario, tenancy_id, today)}

        :already_commenced ->
          Logger.info("Seeder skipped #{inspect(tenancy_id)}: already commenced")
          {:skipped, []}
      end

    # Populate the disposable Directory (ADR 0008) with the tenancy's display identity
    # — a direct Ash upsert, off the event log. Done for `:seeded` **and** `:skipped`
    # alike so a re-seed still refreshes identity for an already-commenced board.
    upsert_directory(scenario, tenancy_id)

    %{scenario: scenario, tenancy_id: tenancy_id, status: status, steps: steps}
  end

  # Resolve deterministic identity (name off tenancy_id, address off property_ref) and
  # upsert it into the Directory read model. Idempotent on `tenancy_id`.
  defp upsert_directory(%Scenario{} = scenario, tenancy_id) do
    %{tenant_name: tenant_name, property_address: property_address} =
      Identity.resolve(tenancy_id, scenario.property_ref)

    Directory
    |> Ash.Changeset.for_create(:upsert, %{
      tenancy_id: tenancy_id,
      tenant_name: tenant_name,
      property_address: property_address
    })
    |> Ash.create!()

    :ok
  end

  # Commence with a backdated booking date (`recorded_on = first_due_date`). Tolerates
  # a re-seed: an already-commenced tenancy is reported, not re-committed.
  defp commence(%Scenario{} = scenario, tenancy_id) do
    command = %CommenceTenancy{
      tenancy_id: tenancy_id,
      # The non-PII property id on the log (ADR 0008). Not prefixed — a re-let pair
      # shares it so the read side derives the same address for the same premises.
      property_ref: scenario.property_ref,
      rent_amount_cents: scenario.rent_amount_cents,
      cycle: scenario.cycle,
      first_due_date: scenario.first_due_date,
      recorded_on: scenario.first_due_date
    }

    case CommandedApp.dispatch(command, consistency: :strong) do
      :ok -> :ok
      {:error, :already_commenced} -> :already_commenced
    end
  end

  # ── pass 2: interleaved replay (single chronological pass) ────────────────────

  # Replay every seeded tenancy's payments / notice / keys-return in ONE pass, ordered
  # by real-world date across streams, so the shared Accounts stream interleaves
  # tenancies the way a live payments book arrives (issue #115).
  defp replay_interleaved(contexts, accounts_stream, await_ms) do
    seeded = Enum.filter(contexts, &(&1.status == :seeded))

    # Subscribe to every tenancy stream up front — before any payment is appended — so
    # no ACL-1 booking is missed once the pass starts appending.
    Enum.each(seeded, &subscribe_to_bookings/1)

    seeded
    |> interleaved_steps()
    |> Enum.each(fn {tenancy_id, step} ->
      run_step(step, tenancy_id, accounts_stream, await_ms)
    end)
  end

  # A transient subscription filtered to ACL-1's output (RentPaymentRecorded) — the
  # deterministic checkpoint the pass awaits after appending each payment, so no
  # sleeping. Per stream, so `await_payment/2` only ever sees our own bookings.
  defp subscribe_to_bookings(%{tenancy_id: tenancy_id}) do
    :ok =
      EventStore.subscribe("tenancy-" <> tenancy_id,
        selector: fn %{data: data} -> match?(%RentPaymentRecorded{}, data) end
      )
  end

  # Merge the seeded tenancies' dated timelines into one totally-ordered pass. The key
  # is `{date, tenancy_id, intra-stream position}`: `date` drives the cross-tenancy
  # interleaving; `tenancy_id` then position are a deterministic, stable tie-break (ADR
  # 0005) — a reseed reproduces the same order, and because a tenancy's own steps share
  # its id and keep their timeline position, its intra-stream order never changes.
  defp interleaved_steps(seeded) do
    seeded
    |> Enum.flat_map(fn %{tenancy_id: tenancy_id, steps: steps} ->
      steps
      |> Enum.with_index()
      |> Enum.map(fn {{date, step}, position} ->
        {{Date.to_erl(date), tenancy_id, position}, tenancy_id, step}
      end)
    end)
    |> Enum.sort_by(fn {sort_key, _tenancy_id, _step} -> sort_key end)
    |> Enum.map(fn {_sort_key, tenancy_id, step} -> {tenancy_id, step} end)
  end

  # ── pass 3: reveal arrears (concurrent sweeps) ────────────────────────────────

  # The visibility backstop: once every payment is booked, sweep each seeded tenancy —
  # booking the RentFellDues owed through today for non-payers. Strong consistency so
  # the Arrears read model reflects the whole catalogue on return. Independent per
  # tenancy, so swept concurrently.
  defp reveal_arrears(contexts, today, max_concurrency) do
    contexts
    |> Enum.filter(&(&1.status == :seeded))
    |> Task.async_stream(
      fn %{tenancy_id: tenancy_id} ->
        :ok =
          CommandedApp.dispatch(Sweep.catch_up_command(tenancy_id, today),
            consistency: :strong
          )
      end,
      max_concurrency: max_concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()
  end

  defp run_step({:payment, %PaymentReceived{} = payment}, _tenancy_id, accounts_stream, await_ms) do
    :ok = Accounts.append(payment, stream: accounts_stream)
    await_payment(payment.payment_id, await_ms)
  end

  defp run_step({:notice, notice}, tenancy_id, _accounts_stream, _await_ms) do
    command = %GiveTerminationNotice{
      tenancy_id: tenancy_id,
      termination_date: notice.termination_date,
      given_on: notice.given_on,
      as_of: notice.as_of,
      recorded_on: notice.given_on
    }

    :ok = CommandedApp.dispatch(command, consistency: :strong)
  end

  defp run_step({:exit, exit}, tenancy_id, _accounts_stream, _await_ms) do
    command = %ReturnKeys{
      tenancy_id: tenancy_id,
      keys_on: exit.keys_on,
      recorded_on: exit.keys_on
    }

    :ok = CommandedApp.dispatch(command, consistency: :strong)
  end

  # Block until ACL-1 has translated the appended payment into a RentPaymentRecorded on
  # the tenancy stream (matched by its source_payment_id, unique per payment).
  defp await_payment(source_payment_id, await_ms) do
    receive do
      {:events, events} ->
        booked? =
          Enum.any?(events, fn recorded ->
            match?(%RentPaymentRecorded{source_payment_id: ^source_payment_id}, recorded.data)
          end)

        if booked?, do: :ok, else: await_payment(source_payment_id, await_ms)
    after
      await_ms ->
        raise "Seeder timed out awaiting RentPaymentRecorded for #{inspect(source_payment_id)}"
    end
  end
end
