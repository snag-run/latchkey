defmodule Latchkey.PropertyManagement.PaymentAclTest do
  @moduledoc """
  Unit tests for ACL-1's pure translation (`PaymentAcl.translate/1`) — no DB, no app.
  The event-in → event-out wiring and the checkpoint live in the integration test.
  """
  use ExUnit.Case, async: true

  alias Latchkey.Accounts.Events.PaymentReceived
  alias Latchkey.Accounts.Events.PaymentReversed
  alias Latchkey.PropertyManagement.PaymentAcl
  alias Latchkey.PropertyManagement.Tenancy.Commands.RecordPayment
  alias Latchkey.PropertyManagement.Tenancy.Commands.ReversePayment

  defp received(attrs) do
    struct(
      %PaymentReceived{
        payment_id: "p1",
        amount_cents: 50_000,
        occurred_on: ~D[2026-01-05],
        recorded_on: ~D[2026-01-06],
        holder: "tenancy-t1"
      },
      attrs
    )
  end

  describe "translate/1 — tenancy-attributed receipt" do
    test "maps a tenancy_ref holder to a RecordPayment command" do
      assert {:ok, %RecordPayment{} = cmd} = PaymentAcl.translate(received(%{}))

      assert cmd.tenancy_id == "t1"
      assert cmd.amount_cents == 50_000
      assert cmd.received_on == ~D[2026-01-05]
      assert cmd.recorded_on == ~D[2026-01-06]
      assert cmd.source_payment_id == "p1"
    end

    test "carries the source payment_id as the idempotency key" do
      assert {:ok, %RecordPayment{source_payment_id: "abc-123"}} =
               PaymentAcl.translate(received(%{payment_id: "abc-123"}))
    end

    test "occurrence date becomes the command's received_on" do
      assert {:ok, %RecordPayment{received_on: ~D[2026-02-09]}} =
               PaymentAcl.translate(received(%{occurred_on: ~D[2026-02-09]}))
    end

    test "coerces the ISO-string dates a JSON replay returns back to Date" do
      assert {:ok, %RecordPayment{received_on: ~D[2026-01-05], recorded_on: ~D[2026-01-06]}} =
               PaymentAcl.translate(
                 received(%{occurred_on: "2026-01-05", recorded_on: "2026-01-06"})
               )
    end
  end

  defp reversed(attrs) do
    struct(
      %PaymentReversed{
        payment_id: "r1",
        reverses: "p1",
        amount_cents: -50_000,
        occurred_on: ~D[2026-01-10],
        recorded_on: ~D[2026-01-11],
        reason: "dishonoured"
      },
      attrs
    )
  end

  describe "translate_reversal/2 — reversal fact → ReversePayment command" do
    test "builds a negative ReversePayment carrying reason and the reverses link" do
      assert {:ok, %ReversePayment{} = cmd} = PaymentAcl.translate_reversal(reversed(%{}), "t1")

      assert cmd.tenancy_id == "t1"
      assert cmd.amount_cents == -50_000
      assert cmd.reversed_on == ~D[2026-01-10]
      assert cmd.recorded_on == ~D[2026-01-11]
      # the reversal's own payment_id is the idempotency key
      assert cmd.source_payment_id == "r1"
      assert cmd.reason == "dishonoured"
      assert cmd.reverses == "p1"
    end

    test "coerces the ISO-string dates a JSON replay returns back to Date" do
      assert {:ok, %ReversePayment{reversed_on: ~D[2026-01-10], recorded_on: ~D[2026-01-11]}} =
               PaymentAcl.translate_reversal(
                 reversed(%{occurred_on: "2026-01-10", recorded_on: "2026-01-11"}),
                 "t1"
               )
    end

    test "reports a malformed date rather than raising" do
      assert {:error, :malformed_date} =
               PaymentAcl.translate_reversal(reversed(%{occurred_on: "not-a-date"}), "t1")
    end
  end

  describe "translate/1 — money that must not cross the seam" do
    test "an UNKNOWN-held receipt is skipped" do
      assert :skip = PaymentAcl.translate(received(%{holder: "UNKNOWN"}))
    end

    test "a blank holder is skipped" do
      assert :skip = PaymentAcl.translate(received(%{holder: ""}))
    end

    test "a holder that is not a well-formed tenancy_ref is skipped" do
      assert :skip = PaymentAcl.translate(received(%{holder: "acct-99"}))
    end

    test "a bare prefix with no id is skipped" do
      assert :skip = PaymentAcl.translate(received(%{holder: "tenancy-"}))
    end
  end
end
