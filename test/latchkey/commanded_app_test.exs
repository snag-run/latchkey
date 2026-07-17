defmodule Latchkey.CommandedAppTest do
  @moduledoc """
  The strong-dispatch error seam (issue #149). An infrastructure dispatch failure —
  chiefly `:consistency_timeout` — must surface as an actionable raise, never fall
  through to a `CaseClauseError` with no signal about the real cause. The happy path
  and the real Commanded dispatch are proven in the seeder/sweep integration tests;
  here we pin the pure result-handling that every `consistency: :strong` call site
  now routes through.
  """
  use ExUnit.Case, async: true

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Tenancy.Commands.CommenceTenancy

  @command %CommenceTenancy{tenancy_id: "t-1", property_ref: "prop-1"}

  describe "handle_strong_result/3" do
    test ":ok passes straight through" do
      assert CommandedApp.handle_strong_result(:ok, @command, [:already_commenced]) == :ok
    end

    test "an expected business error is returned for the caller to handle" do
      assert CommandedApp.handle_strong_result(
               {:error, :already_commenced},
               @command,
               [:already_commenced]
             ) == {:error, :already_commenced}
    end

    test "a :consistency_timeout raises an actionable error, not a CaseClauseError" do
      # It raises even though a business error is expected — the timeout is not one of
      # them, so it must never be mistaken for (or swallowed as) an expected outcome.
      assert_raise RuntimeError, ~r/consistency[_ ]timeout/i, fn ->
        CommandedApp.handle_strong_result(
          {:error, :consistency_timeout},
          @command,
          [:already_commenced]
        )
      end
    end

    test "the :consistency_timeout message names the command, the Neon non-pooler remedy, and the half-seed risk" do
      err =
        assert_raise RuntimeError, fn ->
          CommandedApp.handle_strong_result({:error, :consistency_timeout}, @command, [])
        end

      msg = Exception.message(err)
      assert msg =~ "CommenceTenancy"
      assert msg =~ ~r/Neon/
      assert msg =~ ~r/non-pooler|direct/
      assert msg =~ ~r/appended/
    end

    test "any other dispatch error also raises actionably rather than being swallowed" do
      err =
        assert_raise RuntimeError, ~r/failed/i, fn ->
          CommandedApp.handle_strong_result({:error, :some_other_error}, @command, [])
        end

      assert Exception.message(err) =~ ":some_other_error"
    end
  end
end
