defmodule Latchkey.Simulation.Seeder do
  @moduledoc """
  Seeds a **named scenario catalogue** — a board of tenancies in interesting, legible
  arrears/exit states, each engineered to sit at a chosen state **today** (ADR 0005
  decision 9 / issue #44). This is what makes the app interactive on load: you walk
  into a board of tenancies and play the agent.

  ## Replays the live loop, never a bulk-append path

  Backhistory is manufactured by replaying the **same** functions the live loop runs,
  parameterised with historical dates (ADR 0005 decision 9):

    * the tenant **behaviour engine** (`Latchkey.Simulation.Behaviour`) produces the
      `PaymentReceived` facts, which are appended to the **Accounts** stream and cross
      **ACL-1** exactly as a live payment does (decision 7 — the seam is
      non-negotiable), and
    * the **sweep** (`Latchkey.PropertyManagement.Sweep` `CatchUp`) books the owed
      `RentFellDue`s for non-payers, revealing their arrears.

  So seeded output is identical to live in decision path + ledger outcomes, modulo the
  deliberately-divergent seeder-assigned `recorded_on` (the backdated booking dates
  that make history look accrued-over-time rather than all-at-once).

  ## Reproducible

  The catalogue is a pure function of `today` (`catalogue/1`); tenancy ids are stable
  slugs and payment ids derive purely from the schedule, so re-seeding a fresh store
  reproduces the same catalogue byte-for-byte (ADR 0005 decision 8, seeded RNG).

  ## Fresh-store seed, not a resumable checkpoint

  This is a **dev/demo** seed: it targets a **fresh store** (`mix ecto.reset && mix run
  priv/repo/seeds.exs`). A re-seed against an already-seeded store detects the commenced
  tenancy and returns `:skipped` **without** re-running — a guard against accidentally
  double-seeding a healthy board, **not** a resumable checkpoint. It deliberately does
  **not** repair a partially-seeded tenancy (one commenced but whose payments/notice/
  sweep did not finish): the intended recovery from a failed seed is drop-and-recreate,
  not in-place repair. Hardening this into a resumable seeder is out of scope here.

  ## Await, then reveal

  Payments cross ACL-1 **asynchronously**, so `seed/1` subscribes to each tenancy
  stream and waits for the `RentPaymentRecorded` before advancing — guaranteeing a
  later planted notice (or the final sweep) folds over the payments that precede it.
  The closing `CatchUp` (as of today) is dispatched with `consistency: :strong`, so on
  return the `Arrears` read model reflects the whole catalogue.

  ## Catalogue

    * `paid-up` — a reliable tenant, square today (the calm baseline).
    * `20-days-behind-no-notice` — paid two weeks, then went silent; `days_behind`
      sits at 20 today, past the L7 gate but with **no** notice issued — the eligible
      button waiting to be pulled (ADR 0005 decision 1).
    * `notice-issued-then-tenant-paid` — fell into arrears, the agent issued a
      termination notice, then the tenant paid off the whole debt in one lump. A
      **void candidate**: the notice stands over a now-paid-up, still-ending tenancy.
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
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.Simulation.Behaviour
  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Schedule
  alias Latchkey.Simulation.Seeder.Scenario

  @rent_cents 50_000
  @week_days 7
  @default_await_ms 5_000

  # ── the catalogue (pure) ──────────────────────────────────────────────────────

  @doc """
  The scenario catalogue as a pure function of `today` (defaults to the live Sydney
  date). Every date is an offset from `today`, so each tenancy lands at its intended
  state *as of that day* regardless of when the seed runs.
  """
  @spec catalogue(Date.t()) :: [Scenario.t()]
  def catalogue(today \\ Clock.today()) do
    [paid_up(today), twenty_days_behind(today), notice_then_paid(today)]
  end

  # A reliable tenant who has paid every period up to today — square, `days_behind` 0.
  defp paid_up(today) do
    %Scenario{
      label: "paid-up",
      tenancy_id: "paid-up",
      rent_amount_cents: @rent_cents,
      first_due_date: days_before(today, 30),
      profile: Profile.reliable(),
      schedule_count: 5,
      notice: nil,
      expected: %{
        status: :active,
        oldest_unpaid_due_date: nil,
        days_behind: 0,
        balance_cents: 0
      }
    }
  end

  # Paid two weeks on time, then went silent. The first unpaid period fell due 20 days
  # ago, so `days_behind` is 20 today — eligible under L7, but no notice is planted.
  defp twenty_days_behind(today) do
    %Scenario{
      label: "20-days-behind-no-notice",
      tenancy_id: "arrears-no-notice",
      rent_amount_cents: @rent_cents,
      first_due_date: days_before(today, 34),
      profile: Profile.reliable(),
      schedule_count: 2,
      notice: nil,
      expected: %{
        status: :active,
        oldest_unpaid_due_date: days_before(today, 20),
        days_behind: 20,
        # 5 weekly charges booked through today, 2 paid → 3 weeks outstanding.
        balance_cents: 3 * @rent_cents
      }
    }
  end

  # Missed the opening weeks; the agent issued a termination notice 21 days ago; then
  # the tenant paid the entire debt in one lump. The notice's end date is a week out,
  # so no more rent accrues past it — the tenant is square today, still `:ending`.
  defp notice_then_paid(today) do
    lump_cents = 7 * @rent_cents

    profile =
      Profile.reliable()
      |> Profile.with_override(0, :miss)
      |> Profile.with_override(1, :miss)
      |> Profile.with_override(2, :miss)
      |> Profile.with_override(3, :miss)
      |> Profile.with_override(4, {:pay, amount_cents: lump_cents})

    %Scenario{
      label: "notice-issued-then-tenant-paid",
      tenancy_id: "notice-then-paid",
      rent_amount_cents: @rent_cents,
      first_due_date: days_before(today, 42),
      profile: profile,
      schedule_count: 5,
      notice: %{
        given_on: days_before(today, 21),
        as_of: days_before(today, 21),
        termination_date: Date.add(today, @week_days)
      },
      expected: %{
        status: :ending,
        oldest_unpaid_due_date: nil,
        days_behind: 0,
        balance_cents: 0
      }
    }
  end

  # ── seeding (impure — dispatches through the live seam) ───────────────────────

  @doc """
  Seed the catalogue through the live command → read-model seam. Returns one result
  map per scenario: `%{scenario, tenancy_id, status}` where `status` is `:seeded` or
  `:skipped` (already commenced).

  Options:

    * `:today` — the reference date (defaults to `Clock.today/0`).
    * `:id_prefix` — prepended to each `tenancy_id` for stream isolation (tests pass a
      unique prefix; the real seed leaves it `""` for stable, legible ids).
    * `:accounts_stream` — the Accounts stream payments are appended to (defaults to
      `"accounts"`; tests key it uniquely).
    * `:await_ms` — per-payment await timeout (defaults to `#{@default_await_ms}`).
  """
  @spec seed(keyword()) :: [%{scenario: Scenario.t(), tenancy_id: String.t(), status: atom()}]
  def seed(opts \\ []) do
    today = Keyword.get(opts, :today, Clock.today())
    prefix = Keyword.get(opts, :id_prefix, "")
    accounts_stream = Keyword.get(opts, :accounts_stream, "accounts")
    await_ms = Keyword.get(opts, :await_ms, @default_await_ms)

    today
    |> catalogue()
    |> Enum.map(&seed_scenario(&1, today, prefix, accounts_stream, await_ms))
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

  # Replay the tenant's payments + any planted notice in chronological order, then
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
    |> steps(tenancy_id)
    |> Enum.each(&run_step(&1, tenancy_id, accounts_stream, await_ms))

    # The visibility backstop: book the RentFellDues owed through today for non-payers.
    # Strong consistency so the Arrears read model reflects the whole catalogue on return.
    :ok = CommandedApp.dispatch(Sweep.catch_up_command(tenancy_id, today), consistency: :strong)
  end

  # The chronologically-ordered timeline: engine payments (by received date) merged with
  # the planted notice (by given date). A notice sorts before a payment on the same date,
  # so it folds before any same-day payment (defensive; the catalogue has no such tie).
  defp steps(%Scenario{} = scenario, tenancy_id) do
    payment_steps =
      scenario.profile
      |> Behaviour.payments(schedule(scenario, tenancy_id))
      |> Enum.map(fn %PaymentReceived{} = p -> {p.occurred_on, 1, {:payment, p}} end)

    notice_steps =
      case scenario.notice do
        nil -> []
        %{given_on: given_on} = notice -> [{given_on, 0, {:notice, notice}}]
      end

    (payment_steps ++ notice_steps)
    |> Enum.sort_by(fn {date, tiebreak, _step} -> {Date.to_erl(date), tiebreak} end)
    |> Enum.map(fn {_date, _tiebreak, step} -> step end)
  end

  defp schedule(%Scenario{} = scenario, tenancy_id) do
    Schedule.weekly(
      "tenancy-" <> tenancy_id,
      scenario.first_due_date,
      scenario.rent_amount_cents,
      scenario.schedule_count
    )
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

  defp days_before(%Date{} = date, days), do: Date.add(date, -days)
end
