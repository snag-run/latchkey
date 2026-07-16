defmodule Latchkey.Simulation.SeederTest do
  @moduledoc """
  Unit tests for the **pure** scenario catalogue (issue #44). The catalogue is a
  deterministic function of `today`; the impure seam (dispatching through Accounts →
  ACL-1 → PM and asserting the `Arrears` read model) is exercised in
  `Latchkey.Simulation.SeederIntegrationTest`.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Simulation.Behaviour
  alias Latchkey.Simulation.Schedule
  alias Latchkey.Simulation.Seeder
  alias Latchkey.Simulation.Seeder.Projection
  alias Latchkey.Simulation.Seeder.Scenario

  @today ~D[2026-06-15]

  describe "catalogue/1" do
    test "includes at least the three required named scenarios" do
      labels = @today |> Seeder.catalogue() |> Enum.map(& &1.label)

      assert "paid-up" in labels
      assert "20-days-behind-no-notice" in labels
      assert "notice-issued-then-tenant-paid" in labels
    end

    test "is a deterministic (pure) function of today — same catalogue on re-run" do
      assert Seeder.catalogue(@today) == Seeder.catalogue(@today)
    end

    test "dates are relative to today, so a different today shifts the whole board" do
      other = ~D[2026-09-01]

      refute Seeder.catalogue(@today) == Seeder.catalogue(other)

      # But the relationships hold: the 20-days-behind oldest-unpaid is still today − 20.
      behind = fetch(other, "20-days-behind-no-notice")
      assert behind.expected.oldest_unpaid_due_date == Date.add(other, -20)
    end

    test "every scenario carries a well-formed expected as-of-today state" do
      for %Scenario{expected: expected} <- Seeder.catalogue(@today) do
        assert expected.status in [:active, :ending, :terminal]
        assert is_integer(expected.days_behind) and expected.days_behind >= 0
        assert is_integer(expected.balance_cents)
      end
    end
  end

  describe "scenario shapes" do
    test "paid-up expects a square, active tenant" do
      paid_up = fetch(@today, "paid-up")

      assert paid_up.expected.status == :active
      assert paid_up.expected.oldest_unpaid_due_date == nil
      assert paid_up.expected.days_behind == 0
      assert paid_up.expected.balance_cents == 0
    end

    test "20-days-behind expects 20 days past the oldest unpaid due date, no notice" do
      behind = fetch(@today, "20-days-behind-no-notice")

      # A lenient agent (30-day threshold) — the arrears cross it only in the future, so
      # no notice is derived into the ≤today slice and the tenancy stays active.
      assert behind.agent_archetype == :lenient
      assert behind.expected.status == :active
      assert behind.expected.oldest_unpaid_due_date == Date.add(@today, -20)
      assert behind.expected.days_behind == 20
      assert behind.expected.balance_cents > 0
    end

    test "notice-then-paid derives a notice and expects a paid-up, still-ending tenancy" do
      void = fetch(@today, "notice-issued-then-tenant-paid")

      # No planted dates — the strict agent's notice falls out of the arrears trajectory,
      # its future vacate date keeping the paid-off tenancy ending, not terminal.
      assert void.agent_archetype == :strict
      assert void.expected.status == :ending
      assert void.expected.oldest_unpaid_due_date == nil
      assert void.expected.days_behind == 0
      assert void.expected.balance_cents == 0
    end
  end

  describe "reproducible behaviour (seeded engine)" do
    test "each scenario's engine payments are identical across independent catalogue builds" do
      # Two independently-generated catalogues — determinism means their matching
      # scenarios yield byte-identical payment sequences.
      first = Seeder.catalogue(@today)
      second = Seeder.catalogue(@today)

      for %Scenario{label: label} = scenario <- first do
        twin = Enum.find(second, &(&1.label == label))
        assert engine_payments(scenario) == engine_payments(twin)
      end
    end

    test "the void candidate clears the whole accrued debt so it is square today" do
      void = fetch(@today, "notice-issued-then-tenant-paid")

      # It misses the opening weeks (building the arrears the notice reacts to), then a
      # lump covering those missed weeks, and keeps current — netting to square today.
      payments = engine_payments(void)
      paid_total = payments |> Enum.map(& &1.amount_cents) |> Enum.sum()

      assert Enum.any?(payments, &(&1.amount_cents == 3 * void.rent_amount_cents))
      assert paid_total == 4 * void.rent_amount_cents
      assert void.expected.balance_cents == 0
    end
  end

  describe "catalogue at demo scale (ADR 0007)" do
    test "fills a ~106-tenancy board" do
      assert length(Seeder.catalogue(@today)) == 106
    end

    test "spreads across active, ending and terminal states" do
      by_status = @today |> Seeder.catalogue() |> Enum.group_by(& &1.expected.status)

      # A realistic board: mostly live tenancies, a slice under notice, a few exited.
      assert map_size(Map.take(by_status, [:active, :ending, :terminal])) == 3
      assert length(by_status[:active]) > length(by_status[:ending])
      assert length(by_status[:ending]) > length(by_status[:terminal])
      assert by_status[:terminal] != []
    end

    test "every scenario id and label is unique" do
      catalogue = Seeder.catalogue(@today)
      ids = Enum.map(catalogue, & &1.tenancy_id)
      labels = Enum.map(catalogue, & &1.label)

      assert length(Enum.uniq(ids)) == length(ids)
      assert length(Enum.uniq(labels)) == length(labels)
    end

    test "exited scenarios derive a keys-return and settle to terminal" do
      exited =
        @today |> Seeder.catalogue() |> Enum.filter(&(&1.expected.status == :terminal))

      assert exited != []

      for %Scenario{} = scenario <- exited do
        # No planted dates — a silent tenant deep enough in arrears that the derived
        # notice → E → V all fall in the past, so the keys-return is in the ≤today slice
        # and the tenancy has settled. Deeply behind by construction (cleared L7 long ago).
        assert scenario.expected.status == :terminal
        assert scenario.profile.archetype == :deteriorating
      end
    end

    test "seeds re-let pairs: a prior terminal + a live successor sharing property_ref" do
      catalogue = Seeder.catalogue(@today)

      priors = Enum.filter(catalogue, &String.ends_with?(&1.label, "-prior"))
      currents = Enum.filter(catalogue, &String.ends_with?(&1.label, "-current"))

      # A visible slice of re-let pairs (one prior + one current per premises).
      assert priors != []
      assert length(priors) == length(currents)

      for %Scenario{tenancy_id: "relet-" <> n} = prior <- priors do
        slice = String.trim_trailing(n, "-prior")
        current = Enum.find(currents, &(&1.tenancy_id == "relet-#{slice}-current"))

        # Same premises: shared property_ref → the read side derives one address.
        assert prior.property_ref == current.property_ref
        # Distinct tenancies: different ids → different tenants.
        assert prior.tenancy_id != current.tenancy_id

        # Prior is terminal; current is live, commencing after the prior tenancy's
        # *derived* keys-return — no overlapping occupancy on the shared premises.
        assert prior.expected.status == :terminal
        assert current.expected.status == :active
        assert Date.after?(current.first_due_date, prior_keys_on(prior))
      end
    end

    test "every property_ref is unique except across a re-let pair" do
      catalogue = Seeder.catalogue(@today)
      refs = Enum.map(catalogue, & &1.property_ref)

      # Only the re-let pairs share a ref, so #shared refs = #pairs; all others unique.
      shared = refs -- Enum.uniq(refs)
      pairs = Enum.count(catalogue, &String.ends_with?(&1.label, "-prior"))

      assert length(shared) == pairs
      assert Enum.all?(catalogue, &is_binary(&1.property_ref))
    end

    test "generated notices all clear the L7 arrears gate (no domain-invalid scenario)" do
      # `catalogue/1` derives every `:expected` through the real domain, which raises on
      # a domain-invalid step — so a clean build *is* the validity assertion. Assert it
      # explicitly so a future generator regression fails here, loudly.
      assert Seeder.catalogue(@today) |> Enum.all?(&match?(%{status: _}, &1.expected))
    end
  end

  defp fetch(today, label) do
    today |> Seeder.catalogue() |> Enum.find(&(&1.label == label))
  end

  # The scenario's *derived* keys-return date (`V`) — pulled from the same world-line
  # ≤today slice the seeder replays, so the assertion tracks the real vacate date.
  defp prior_keys_on(%Scenario{} = scenario) do
    scenario
    |> Projection.dated_timeline(scenario.tenancy_id, @today)
    |> Enum.find_value(fn
      {_date, {:exit, %{keys_on: keys_on}}} -> keys_on
      _step -> nil
    end)
  end

  defp engine_payments(%Scenario{} = scenario) do
    schedule =
      Schedule.weekly(
        "tenancy-" <> scenario.tenancy_id,
        scenario.first_due_date,
        scenario.rent_amount_cents,
        scenario.schedule_count
      )

    Behaviour.payments(scenario.profile, schedule)
  end
end
