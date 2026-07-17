defmodule Latchkey.Simulation.SeedGenerationTest do
  @moduledoc """
  The **seed-generation counter** (spec `docs/spec/simulation-engine.md`, "Reset carries
  a seed generation"; issue #162): the single monotonic integer reset advances before it
  purges + replans. These pin the storage contract — a `0` baseline, and an atomic,
  never-regressing `advance/0` — that the planner stamp and the dispatch guard rely on.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.Simulation.SeedGeneration

  test "current/0 starts at the 0 baseline" do
    assert SeedGeneration.current() == 0
  end

  test "advance/0 bumps by one and returns the new generation" do
    assert SeedGeneration.advance() == 1
    assert SeedGeneration.current() == 1

    assert SeedGeneration.advance() == 2
    assert SeedGeneration.current() == 2
  end

  test "advance/0 is monotonic — the generation only ever moves forward" do
    values = for _ <- 1..5, do: SeedGeneration.advance()

    assert values == [1, 2, 3, 4, 5]
  end
end
