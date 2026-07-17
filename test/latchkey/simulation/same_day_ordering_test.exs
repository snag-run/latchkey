defmodule Latchkey.Simulation.SameDayOrderingTest do
  @moduledoc """
  Regression guard for issue #161 — same-day dispatch order of a planned **payment**
  job and the midnight **sweep** (`CatchUp`, which books `RentFellDue`) is immaterial
  to the folded **arrears**.

  The simulation runtime is a **dumb dispatch**: notice/vacate are decided at plan
  time by the deterministic world-line, never from a runtime arrears read — so
  same-day booking order cannot change any agent decision. This test pins the second
  half of that rationale: for the *reads* that matter, the fold is order-independent.

  A `RentPaymentRecorded` and a `RentFellDue` write to **disjoint** aggregate-state
  fields (`payments_total_cents`/`applied_payment_ids` vs the `charges` list), so the
  two `evolve/2` steps commute. The whole folded state — and therefore every derived
  arrears field (`balance_cents`, `oldest_unpaid_due_date`, `days_behind`) — is
  identical whether the sweep books the charge before or after the payment folds.
  """
  use ExUnit.Case, async: true

  alias Latchkey.PropertyManagement.ArrearsFold
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced

  @tenancy_id "tenancy-t1"
  @property_ref "prop-abc"
  @rent 50_000

  # Weekly tenancy commencing on its first due date, charged four whole periods.
  defp commenced do
    %TenancyCommenced{
      tenancy_id: @tenancy_id,
      property_ref: @property_ref,
      occurred_on: ~D[2025-01-01],
      recorded_on: ~D[2025-01-01],
      rent_amount_cents: @rent,
      cycle: :weekly,
      first_due_date: ~D[2025-01-01]
    }
  end

  defp rent_fell_due(due_on) do
    %RentFellDue{
      tenancy_id: @tenancy_id,
      occurred_on: due_on,
      recorded_on: due_on,
      amount_cents: @rent,
      period_from: due_on,
      period_to: Date.add(due_on, 7)
    }
  end

  defp payment(received_on, amount_cents, source_payment_id) do
    %RentPaymentRecorded{
      tenancy_id: @tenancy_id,
      occurred_on: received_on,
      recorded_on: received_on,
      amount_cents: amount_cents,
      source_payment_id: source_payment_id
    }
  end

  describe "same-day payment vs sweep (RentFellDue) dispatch order" do
    # Prior periods already booked; on the same date a fourth period falls due (sweep)
    # and a partial payment lands, leaving the tenant mid-stream in arrears so
    # `oldest_unpaid_due_date` (FIFO) is a non-trivial value, not merely `nil`.
    @same_day ~D[2025-01-22]

    setup do
      prior_charges = [
        rent_fell_due(~D[2025-01-01]),
        rent_fell_due(~D[2025-01-08]),
        rent_fell_due(~D[2025-01-15])
      ]

      same_day_charge = rent_fell_due(@same_day)
      # 2.4 periods' worth: clears periods 0–1, leaves period 2 (2025-01-15) as the
      # oldest unpaid — a mid-stream FIFO result the ordering must not perturb.
      same_day_payment = payment(@same_day, 120_000, "pay-1")

      base = [commenced() | prior_charges]

      %{
        sweep_then_payment: base ++ [same_day_charge, same_day_payment],
        payment_then_sweep: base ++ [same_day_payment, same_day_charge]
      }
    end

    test "produces identical folded arrears either way", ctx do
      sweep_then_payment = ArrearsFold.fold_and_derive(ctx.sweep_then_payment, @same_day)
      payment_then_sweep = ArrearsFold.fold_and_derive(ctx.payment_then_sweep, @same_day)

      assert sweep_then_payment == payment_then_sweep
    end

    test "balance and FIFO oldest-unpaid are order-independent", ctx do
      sweep_then_payment = ArrearsFold.fold_and_derive(ctx.sweep_then_payment, @same_day)
      payment_then_sweep = ArrearsFold.fold_and_derive(ctx.payment_then_sweep, @same_day)

      # Four periods booked (200_000) less a 120_000 payment.
      assert sweep_then_payment.balance_cents == 80_000
      assert payment_then_sweep.balance_cents == 80_000

      # 120_000 clears 2025-01-01 and 2025-01-08; 2025-01-15 is the oldest unpaid.
      assert sweep_then_payment.oldest_unpaid_due_date == ~D[2025-01-15]
      assert payment_then_sweep.oldest_unpaid_due_date == ~D[2025-01-15]

      assert sweep_then_payment.days_behind == payment_then_sweep.days_behind
    end
  end
end
