defmodule Latchkey.Simulation.Seeder.ProjectionTest do
  @moduledoc """
  Unit tests for the **pure** projection that derives a scenario's as-of-today
  read-model state (ADR 0007). It drives the real `Tenancy` domain, so these assert
  the derivation is faithful and that the agent's notice/keys-return are **derived**
  from the world-line's `≤ today` slice (ADR 0011), not planted.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Simulation.Behaviour.Profile
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario

  @today ~D[2026-06-15]

  describe "derive/2" do
    test "a reliable tenant paid up to today is square and active" do
      # first_due offset so the *next* due date lands after today — nothing dangles unpaid.
      scenario = %Scenario{
        label: "square",
        tenancy_id: "square",
        property_ref: "prop-square",
        rent_amount_cents: 50_000,
        first_due_date: Date.add(@today, -27),
        profile: Profile.reliable(),
        schedule_count: 4
      }

      assert %{
               status: :active,
               balance_cents: 0,
               oldest_unpaid_due_date: nil,
               days_behind: 0
             } = Projection.derive(scenario, @today)
    end

    test "a tenant who stopped paying surfaces the exact arrears the sweep reveals" do
      # Paid one week, then silent; first unpaid fell due 21 days ago.
      scenario = %Scenario{
        label: "behind",
        tenancy_id: "behind",
        property_ref: "prop-behind",
        rent_amount_cents: 50_000,
        first_due_date: Date.add(@today, -28),
        profile: Profile.reliable(),
        schedule_count: 1
      }

      derived = Projection.derive(scenario, @today)

      assert derived.status == :active
      assert derived.oldest_unpaid_due_date == Date.add(@today, -21)
      assert derived.days_behind == 21
      assert derived.balance_cents > 0
    end

    test "a fortnightly reliable tenant paid up to today is square and active" do
      # Periods due today-40, today-26, today-12 (all ≤ today, paid); next period
      # (today+2) is future, so nothing dangles — a truthful fortnightly fold.
      scenario = %Scenario{
        label: "fortnightly-square",
        tenancy_id: "fortnightly-square",
        property_ref: "prop-fn-square",
        rent_amount_cents: 60_000,
        first_due_date: Date.add(@today, -40),
        cycle: :fortnightly,
        profile: Profile.reliable(),
        schedule_count: 3
      }

      assert %{
               status: :active,
               balance_cents: 0,
               oldest_unpaid_due_date: nil,
               days_behind: 0
             } = Projection.derive(scenario, @today)
    end

    test "a monthly reliable tenant paid up to today is square and active" do
      # Anchor Apr 20: periods Apr 20 and May 20 are ≤ today (2026-06-15) and paid; the
      # next monthly period (Jun 20) is future, so the tenant is square.
      scenario = %Scenario{
        label: "monthly-square",
        tenancy_id: "monthly-square",
        property_ref: "prop-mo-square",
        rent_amount_cents: 200_000,
        first_due_date: ~D[2026-04-20],
        cycle: :monthly,
        profile: Profile.reliable(),
        schedule_count: 2
      }

      assert %{
               status: :active,
               balance_cents: 0,
               oldest_unpaid_due_date: nil,
               days_behind: 0
             } = Projection.derive(scenario, @today)
    end

    test "a monthly tenant behind one month surfaces the real month span the sweep reveals" do
      # Anchor Apr 20, pays only the first month. May 20 falls due unpaid; the sweep as of
      # today (Jun 15) reveals it — days_behind counts the *actual* days since May 20, and
      # exactly one whole monthly period is owed.
      scenario = %Scenario{
        label: "monthly-behind",
        tenancy_id: "monthly-behind",
        property_ref: "prop-mo-behind",
        rent_amount_cents: 200_000,
        first_due_date: ~D[2026-04-20],
        cycle: :monthly,
        profile: Profile.reliable(),
        schedule_count: 1
      }

      derived = Projection.derive(scenario, @today)

      assert derived.status == :active
      assert derived.oldest_unpaid_due_date == ~D[2026-05-20]
      # Date.diff(~D[2026-06-15], ~D[2026-05-20]) — the real elapsed days, not a 7-day guess.
      assert derived.days_behind == 26
      assert derived.balance_cents == 200_000
    end

    test "derives a notice + keys-return for a silent, deeply-behind tenant (terminal)" do
      # Pays two weeks then goes silent; a strict agent notices at 14 days behind, and
      # with the notice/E/V all in the past the derived keys-return lands in the ≤today
      # slice — the tenancy settles to terminal, no dates planted.
      scenario = silent_scenario("terminal", first_due: Date.add(@today, -70), overstay: 0)

      derived = Projection.derive(scenario, @today)

      assert derived.status == :terminal
    end

    test "a future termination/vacate date keeps a noticed tenant ending, not terminal" do
      # Same silent tenant, but recently enough that the derived notice is served while
      # its termination date E (and V) are still in the future — so no keys-return is in
      # the ≤today slice and the tenancy is ending today.
      scenario = silent_scenario("ending", first_due: Date.add(@today, -35), overstay: 0)

      derived = Projection.derive(scenario, @today)

      assert derived.status == :ending
      assert derived.days_behind >= 14
    end
  end

  describe "timeline/3" do
    test "orders derived payments, notice and exit chronologically (≤ today)" do
      scenario = silent_scenario("ordered", first_due: Date.add(@today, -70), overstay: 0)

      steps = Projection.timeline(scenario, scenario.tenancy_id, @today)

      kinds = Enum.map(steps, &elem(&1, 0))
      assert kinds == [:payment, :payment, :notice, :exit]

      dates =
        Enum.map(steps, fn
          {:payment, %PaymentReceived{occurred_on: on}} -> on
          {:notice, %{given_on: on}} -> on
          {:exit, %{keys_on: on}} -> on
        end)

      assert dates == Enum.sort(dates, Date)
    end

    test "excludes steps after today (the planner's future slice)" do
      # Recently silent: the notice is served but E/V are still in the future, so the
      # ≤today timeline carries the payments and the notice, but no keys-return.
      scenario = silent_scenario("future-exit", first_due: Date.add(@today, -35), overstay: 0)

      kinds =
        scenario |> Projection.timeline(scenario.tenancy_id, @today) |> Enum.map(&elem(&1, 0))

      assert :notice in kinds
      refute :exit in kinds
    end
  end

  describe "future_timeline/3 — the planner's > today slice" do
    test "a reliable tenant's future periods are scheduled as payment steps" do
      # first_due today-14, weekly, 8 periods → three periods ≤ today (paid, square) and
      # the rest ahead — the runway the catalogue now adds so the tenant keeps paying.
      scenario = %Scenario{
        label: "ongoing",
        tenancy_id: "ongoing",
        property_ref: "prop-ongoing",
        rent_amount_cents: 50_000,
        first_due_date: Date.add(@today, -14),
        profile: Profile.reliable(),
        schedule_count: 8
      }

      future = Projection.future_timeline(scenario, scenario.tenancy_id, @today)

      # Every future step is a payment (a reliable tenant never crosses a threshold), each
      # dated strictly after today.
      assert future != []
      assert Enum.all?(future, fn {_date, {kind, _}} -> kind == :payment end)
      assert Enum.all?(future, fn {date, _} -> Date.after?(date, @today) end)

      # Extending the schedule past today leaves the as-of-today read model untouched.
      assert %{status: :active, days_behind: 0, balance_cents: 0} =
               Projection.derive(scenario, @today)
    end

    test "a silent tenant schedules no future payments" do
      # Pays two periods then goes silent — its only payments are in the past, so the
      # future slice carries no payment steps (the silence keeps it accruing, by design).
      scenario = silent_scenario("silent-future", first_due: Date.add(@today, -70), overstay: 0)

      future = Projection.future_timeline(scenario, scenario.tenancy_id, @today)

      refute Enum.any?(future, fn {_date, {kind, _}} -> kind == :payment end)
    end
  end

  describe "dated_timeline/3" do
    test "pairs each step with its own ordering date, oldest first, matching timeline/3" do
      scenario = silent_scenario("dated", first_due: Date.add(@today, -70), overstay: 0)

      dated = Projection.dated_timeline(scenario, scenario.tenancy_id, @today)

      # Same steps, same order as timeline/3 — just carrying the sort date.
      assert Enum.map(dated, fn {_date, step} -> step end) ==
               Projection.timeline(scenario, scenario.tenancy_id, @today)

      # The paired date is exactly the step's own real-world date.
      for {date, step} <- dated do
        own_date =
          case step do
            {:payment, %PaymentReceived{occurred_on: on}} -> on
            {:notice, %{given_on: on}} -> on
            {:exit, %{keys_on: on}} -> on
          end

        assert date == own_date
      end

      # Oldest first.
      dates = Enum.map(dated, fn {date, _step} -> date end)
      assert dates == Enum.sort(dates, Date)
    end
  end

  # A weekly tenant who pays two periods on time then goes silent — the arrears
  # trajectory a strict agent reacts to. Where the derived notice/E/V land (past vs
  # future) is set by `first_due` and `overstay`, so a caller can steer the ≤today slice.
  defp silent_scenario(id, opts) do
    %Scenario{
      label: id,
      tenancy_id: id,
      property_ref: "prop-#{id}",
      rent_amount_cents: 50_000,
      first_due_date: Keyword.fetch!(opts, :first_due),
      profile: Profile.deteriorating(grace_periods: 2, step_days: 100, period_length_days: 7),
      schedule_count: 4,
      agent_archetype: :strict,
      overstay_days: Keyword.get(opts, :overstay, 0)
    }
  end
end
