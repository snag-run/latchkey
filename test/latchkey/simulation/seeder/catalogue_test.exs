defmodule Latchkey.Simulation.Seeder.CatalogueTest do
  @moduledoc """
  Unit tests for the seed catalogue's **deterministic** 60/30/10 cadence split (ADR
  0009). The board must stay a pure function of `today`, so the per-category cadence
  assignment is asserted exactly against the `rem(idx, 10)` rule, and the three featured
  headliners must stay weekly and be excluded from the split.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Simulation.Seeder.Catalogue

  @today ~D[2026-06-15]

  # The rule under test (ADR 0009 decision 1): a category's local 0-based idx →
  # 0–5 weekly, 6–8 fortnightly, 9 monthly, by pure modulo.
  defp expected_cycle(idx) do
    case rem(idx, 10) do
      r when r in 0..5 -> :weekly
      r when r in 6..8 -> :fortnightly
      _ -> :monthly
    end
  end

  # The 0-based local idx encoded in a generated label like "healthy-07" (1-based pad).
  defp idx_from_label(label) do
    [num] = Regex.run(~r/-(\d{2})(?:-|$)/, label, capture: :all_but_first)
    String.to_integer(num) - 1
  end

  describe "60/30/10 cadence split (deterministic per category)" do
    setup do
      %{catalogue: Catalogue.build(@today)}
    end

    for prefix <- ["healthy", "arrears", "under-notice", "exited"] do
      test "#{prefix} assigns cadence by rem(idx, 10)", %{catalogue: catalogue} do
        prefix = unquote(prefix)

        scenarios =
          Enum.filter(catalogue, fn s -> String.starts_with?(s.label, prefix <> "-") end)

        assert scenarios != []

        for s <- scenarios do
          idx = idx_from_label(s.label)

          assert s.cycle == expected_cycle(idx),
                 "#{s.label} (idx #{idx}) expected #{expected_cycle(idx)}, got #{s.cycle}"
        end
      end
    end

    test "re-let pairs share the pair's cadence, both legs", %{catalogue: catalogue} do
      relets = Enum.filter(catalogue, fn s -> String.starts_with?(s.label, "relet-") end)
      assert relets != []

      for s <- relets do
        idx = idx_from_label(s.label)
        assert s.cycle == expected_cycle(idx)
      end
    end

    test "exact boundary assignments in a full-size category (healthy)", %{catalogue: catalogue} do
      by_label = Map.new(catalogue, fn s -> {s.label, s.cycle} end)

      # idx 0–5 weekly, 6–8 fortnightly, 9 monthly — then the block repeats.
      assert by_label["healthy-01"] == :weekly
      assert by_label["healthy-06"] == :weekly
      assert by_label["healthy-07"] == :fortnightly
      assert by_label["healthy-09"] == :fortnightly
      assert by_label["healthy-10"] == :monthly
      assert by_label["healthy-11"] == :weekly
      assert by_label["healthy-20"] == :monthly
    end

    test "builds every scenario valid-by-construction on any today (incl. month-end clamps)" do
      # Projection.derive/2 raises on a domain-invalid planted step (e.g. a notice that
      # fails the L7 gate). The cadence-aware `back_periods` placement must keep every
      # generated notice/exit valid on every cadence, for any `today` — month-end anchors
      # are where a monthly clamp could otherwise erode the L7 margin.
      todays =
        for month <- 1..12 do
          last = Date.end_of_month(Date.new!(2026, month, 1))
          [last, Date.new!(2026, month, 15), Date.new!(2027, month, 28)]
        end
        |> List.flatten()

      for today <- todays do
        catalogue = Catalogue.build(today)
        assert length(catalogue) > 100
        # Every scenario carries a concrete cadence and a filled, derived expected state.
        assert Enum.all?(catalogue, &(&1.cycle in [:weekly, :fortnightly, :monthly]))
        assert Enum.all?(catalogue, &is_map(&1.expected))
      end
    end

    test "the three featured headliners stay weekly and are excluded from the split",
         %{catalogue: catalogue} do
      featured =
        Enum.filter(catalogue, fn s ->
          s.tenancy_id in ["paid-up", "arrears-no-notice", "notice-then-paid"]
        end)

      assert length(featured) == 3
      assert Enum.all?(featured, &(&1.cycle == :weekly))

      # Featured labels are not "-NN" indexed, so they cannot be part of any generated
      # category's denominator — the split only touches generated scenarios.
      refute Enum.any?(featured, fn s -> String.match?(s.label, ~r/-\d{2}(-|$)/) end)
    end
  end
end
