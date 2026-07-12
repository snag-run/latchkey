defmodule Latchkey.AccountsTest do
  @moduledoc """
  Pure builder + holder-rule tests for the Accounts stub — no event store, no DB.
  Covers the edge-input → uniform-envelope mapping (`received_on`/`reversed_on` →
  `occurred_on`), the `recorded_on` default, and the `UNKNOWN` seam rule.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Accounts
  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Accounts.Events.PaymentReversed
  alias Latchkey.Clock

  describe "payment_received/1" do
    test "maps edge inputs onto the uniform {occurred_on, recorded_on} envelope" do
      event =
        Accounts.payment_received(%{
          payment_id: "p1",
          amount_cents: 50_000,
          received_on: ~D[2026-01-05],
          recorded_on: ~D[2026-01-06],
          holder: "tenancy-1"
        })

      assert %PaymentReceived{
               payment_id: "p1",
               amount_cents: 50_000,
               occurred_on: ~D[2026-01-05],
               recorded_on: ~D[2026-01-06],
               holder: "tenancy-1"
             } = event
    end

    test "defaults recorded_on to the Clock when omitted" do
      event =
        Accounts.payment_received(%{
          payment_id: "p1",
          amount_cents: 50_000,
          received_on: ~D[2026-01-05],
          holder: "tenancy-1"
        })

      assert event.recorded_on == Clock.today()
    end

    test "carries the UNKNOWN holder sentinel unchanged (representable at the edge)" do
      event =
        Accounts.payment_received(%{
          payment_id: "p1",
          amount_cents: 50_000,
          received_on: ~D[2026-01-05],
          holder: Accounts.unknown_holder()
        })

      assert event.holder == "UNKNOWN"
      refute Accounts.known_holder?(event.holder)
    end

    test "raises when a required edge input is missing" do
      assert_raise ArgumentError, fn ->
        Accounts.payment_received(%{amount_cents: 1, received_on: ~D[2026-01-05], holder: "t"})
      end
    end

    test "rejects a non-positive amount (a receipt must be a positive credit)" do
      for bad <- [0, -1] do
        assert_raise ArgumentError, ~r/must be positive/, fn ->
          Accounts.payment_received(%{
            payment_id: "p1",
            amount_cents: bad,
            received_on: ~D[2026-01-05],
            holder: "tenancy-1"
          })
        end
      end
    end
  end

  describe "payment_reversed/1" do
    test "maps reversed_on to occurred_on and carries the negative amount" do
      event =
        Accounts.payment_reversed(%{
          payment_id: "p1-rev",
          reverses: "p1",
          amount_cents: -50_000,
          reversed_on: ~D[2026-01-07],
          recorded_on: ~D[2026-01-07],
          reason: "wrong_holder"
        })

      assert %PaymentReversed{
               payment_id: "p1-rev",
               reverses: "p1",
               amount_cents: -50_000,
               occurred_on: ~D[2026-01-07],
               recorded_on: ~D[2026-01-07],
               reason: "wrong_holder"
             } = event
    end

    test "rejects a non-negative amount (a reversal must be a negative, compensating entry)" do
      for bad <- [0, 1] do
        assert_raise ArgumentError, ~r/must be negative/, fn ->
          Accounts.payment_reversed(%{
            payment_id: "p1-rev",
            reverses: "p1",
            amount_cents: bad,
            reversed_on: ~D[2026-01-07],
            reason: "wrong_holder"
          })
        end
      end
    end
  end

  describe "known_holder?/1" do
    test "a tenancy_ref is attributable; UNKNOWN and blanks are not" do
      assert Accounts.known_holder?("tenancy-42")
      refute Accounts.known_holder?(Accounts.unknown_holder())
      refute Accounts.known_holder?("")
      refute Accounts.known_holder?(nil)
    end
  end

  describe "JSON envelope (ADR 0006 rename)" do
    test "encodes occurred_on/recorded_on and never effective_date" do
      decoded =
        %{
          payment_id: "p1",
          amount_cents: 50_000,
          received_on: ~D[2026-01-05],
          recorded_on: ~D[2026-01-06],
          holder: "tenancy-1"
        }
        |> Accounts.payment_received()
        |> Jason.encode!()
        |> Jason.decode!()

      assert decoded["occurred_on"] == "2026-01-05"
      assert decoded["recorded_on"] == "2026-01-06"
      refute Map.has_key?(decoded, "effective_date")
    end
  end
end
