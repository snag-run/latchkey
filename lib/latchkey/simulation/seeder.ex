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
    * the human agent's **notice** / **keys-return** are dispatched as the real
      `GiveTerminationNotice` / `ReturnKeys` commands; and
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

  ## Await, then reveal

  Payments cross ACL-1 **asynchronously**, so each scenario subscribes to its tenancy
  stream and waits for the `RentPaymentRecorded` before advancing — guaranteeing a
  later planted notice (or the final sweep) folds over the payments that precede it.
  The closing `CatchUp` (as of today) is dispatched with `consistency: :strong`, so on
  return the `Arrears` read model reflects the whole catalogue. Scenarios seed
  concurrently (each on its own stream), bounded by `:max_concurrency`.
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

    scenarios
    |> Task.async_stream(
      &seed_scenario(&1, today, prefix, accounts_stream, await_ms),
      max_concurrency: max_concurrency,
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp seed_scenario(%Scenario{} = scenario, today, prefix, accounts_stream, await_ms) do
    tenancy_id = prefix <> scenario.tenancy_id

    case commence(scenario, tenancy_id) do
      :ok ->
        replay(scenario, tenancy_id, today, accounts_stream, await_ms)
        %{scenario: scenario, tenancy_id: tenancy_id, status: :seeded}

      :already_commenced ->
        Logger.info("Seeder skipped #{inspect(tenancy_id)}: already commenced")
        %{scenario: scenario, tenancy_id: tenancy_id, status: :skipped}
    end
  end

  # Commence with a backdated booking date (`recorded_on = first_due_date`). Tolerates
  # a re-seed: an already-commenced tenancy is reported, not re-committed.
  defp commence(%Scenario{} = scenario, tenancy_id) do
    command = %CommenceTenancy{
      tenancy_id: tenancy_id,
      rent_amount_cents: scenario.rent_amount_cents,
      cycle: :weekly,
      first_due_date: scenario.first_due_date,
      recorded_on: scenario.first_due_date
    }

    case CommandedApp.dispatch(command, consistency: :strong) do
      :ok -> :ok
      {:error, :already_commenced} -> :already_commenced
    end
  end

  # Replay the tenant's payments + any planted notice/exit in chronological order, then
  # reveal arrears with a closing sweep as of today.
  defp replay(%Scenario{} = scenario, tenancy_id, today, accounts_stream, await_ms) do
    stream = "tenancy-" <> tenancy_id

    # Transient subscription filtered to ACL-1's output (RentPaymentRecorded) — the
    # deterministic checkpoint we await after appending each payment, so no sleeping.
    :ok =
      EventStore.subscribe(stream,
        selector: fn %{data: data} -> match?(%RentPaymentRecorded{}, data) end
      )

    scenario
    |> Projection.timeline(tenancy_id)
    |> Enum.each(&run_step(&1, tenancy_id, accounts_stream, await_ms))

    # The visibility backstop: book the RentFellDues owed through today for non-payers.
    # Strong consistency so the Arrears read model reflects the whole catalogue on return.
    :ok = CommandedApp.dispatch(Sweep.catch_up_command(tenancy_id, today), consistency: :strong)
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
