defmodule Latchkey.Simulation.Seeder.ProjectionTest do
  @moduledoc """
  Unit tests for the **pure** projection that derives a scenario's as-of-today
  read-model state (ADR 0007). It drives the real `Tenancy` domain, so these assert
  the derivation is faithful and that a domain-invalid planted step fails loudly.
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

    test "raises with context on a domain-invalid planted step (notice below the L7 gate)" do
      # A paid-up tenant is not in arrears, so the planted notice fails the L7 gate.
      scenario = %Scenario{
        label: "bad-notice",
        tenancy_id: "bad-notice",
        property_ref: "prop-bad-notice",
        rent_amount_cents: 50_000,
        first_due_date: Date.add(@today, -28),
        profile: Profile.reliable(),
        schedule_count: 4,
        notice: %{
          given_on: Date.add(@today, -1),
          as_of: Date.add(@today, -1),
          termination_date: Date.add(@today, 7)
        }
      }

      assert_raise ArgumentError, ~r/domain-invalid step/, fn ->
        Projection.derive(scenario, @today)
      end
    end
  end

  describe "timeline/2" do
    test "orders payments, notice and exit chronologically" do
      scenario = %Scenario{
        label: "ordered",
        tenancy_id: "ordered",
        property_ref: "prop-ordered",
        rent_amount_cents: 50_000,
        first_due_date: Date.add(@today, -70),
        profile: Profile.reliable(),
        schedule_count: 2,
        notice: %{
          given_on: Date.add(@today, -40),
          as_of: Date.add(@today, -40),
          termination_date: Date.add(@today, -12)
        },
        exit: %{keys_on: Date.add(@today, -12)}
      }

      steps = Projection.timeline(scenario, scenario.tenancy_id)

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
  end

  describe "dated_timeline/2" do
    test "pairs each step with its own ordering date, oldest first, matching timeline/2" do
      scenario = %Scenario{
        label: "dated",
        tenancy_id: "dated",
        property_ref: "prop-dated",
        rent_amount_cents: 50_000,
        first_due_date: Date.add(@today, -70),
        profile: Profile.reliable(),
        schedule_count: 2,
        notice: %{
          given_on: Date.add(@today, -40),
          as_of: Date.add(@today, -40),
          termination_date: Date.add(@today, -12)
        },
        exit: %{keys_on: Date.add(@today, -12)}
      }

      dated = Projection.dated_timeline(scenario, scenario.tenancy_id)

      # Same steps, same order as timeline/2 — just carrying the sort date.
      assert Enum.map(dated, fn {_date, step} -> step end) ==
               Projection.timeline(scenario, scenario.tenancy_id)

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
end
