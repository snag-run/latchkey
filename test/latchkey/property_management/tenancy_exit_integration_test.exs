defmodule Latchkey.PropertyManagement.TenancyExitIntegrationTest do
  @moduledoc """
  Full-stack exit settlement through the real Commanded app + Postgres EventStore +
  async projector (prior art: #20 / `TenancyIntegrationTest`). Proves the wiring the
  aggregate unit test can't: `KeysReturned` + `TenancySettled` persist and round-trip,
  and the `Arrears` read model reflects the tenancy as **Terminal** with its final
  balance (a frozen snapshot alongside the live folded balance).

  Streams are keyed by a unique tenancy id per run; the Ash read model is sandboxed
  (shared mode) so the projector and test share the connection.
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C

  require Ash.Query

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    :ok
  end

  # Drive a tenancy to `:ending` with E = 02-16 (a period boundary), 28 days behind.
  defp ending_tenancy(tid) do
    :ok =
      CommandedApp.dispatch(
        %C.CommenceTenancy{
          tenancy_id: tid,
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05]
        },
        consistency: :strong
      )

    :ok =
      CommandedApp.dispatch(
        %C.GiveTerminationNotice{
          tenancy_id: tid,
          termination_date: ~D[2026-02-16],
          given_on: ~D[2026-02-02],
          as_of: ~D[2026-02-02]
        },
        consistency: :strong
      )

    :ok
  end

  # Drive a tenancy to `:ending` with a **mid-week** E = 02-12 (period [02-09, 02-16)),
  # 28 days behind — so exit pro-rates the final boundary period.
  defp midweek_ending_tenancy(tid) do
    :ok =
      CommandedApp.dispatch(
        %C.CommenceTenancy{
          tenancy_id: tid,
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05]
        },
        consistency: :strong
      )

    :ok =
      CommandedApp.dispatch(
        %C.GiveTerminationNotice{
          tenancy_id: tid,
          termination_date: ~D[2026-02-12],
          given_on: ~D[2026-02-02],
          as_of: ~D[2026-02-02]
        },
        consistency: :strong
      )

    :ok
  end

  defp projection(tid) do
    Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()
  end

  test "returning keys reaches Terminal with a persisted positive final balance (debt)" do
    tid = "exit-#{System.unique_integer([:positive])}"
    ending_tenancy(tid)

    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-16]},
               consistency: :strong
             )

    proj = projection(tid)
    # Six weeks booked by exit (01-05..02-09, clamped before E), nothing paid.
    assert proj.status == :terminal
    assert proj.final_balance_cents == 300_000
    # The live folded balance matches the snapshot at settlement (no post-exit events).
    assert proj.balance_cents == 300_000
    assert proj.oldest_unpaid_due_date == ~D[2026-01-05]
  end

  test "a prepaid tenant reaches Terminal with a persisted refund owed (negative)" do
    tid = "exit-#{System.unique_integer([:positive])}"
    ending_tenancy(tid)

    # Prepay $3,500 — more than the $3,000 that will be owed at exit.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 350_000,
                 received_on: ~D[2026-02-10],
                 source_payment_id: "p-#{tid}"
               },
               consistency: :strong
             )

    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-16]},
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.status == :terminal
    # 6 × $500 − $3,500 = −$500 → refund owed, signed negative, declared not disbursed.
    assert proj.final_balance_cents == -50_000
    assert proj.balance_cents == -50_000
  end

  test "a mid-week exit pro-rates the final week through the seam (charged to E, never whole)" do
    tid = "exit-#{System.unique_integer([:positive])}"
    midweek_ending_tenancy(tid)

    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-12]},
               consistency: :strong
             )

    proj = projection(tid)
    # 5 whole weeks 01-05..02-02 ($2,500) + the boundary period [02-09, 02-12) = 3 days
    # of $500/week = round_half_up(500×3/7) = $214.29, nothing paid.
    assert proj.status == :terminal
    assert proj.final_balance_cents == 271_429
    assert proj.balance_cents == 271_429
    assert proj.oldest_unpaid_due_date == ~D[2026-01-05]
  end

  test "a tenant who prepaid the whole final week exits with the correct refund owed" do
    tid = "exit-#{System.unique_integer([:positive])}"
    midweek_ending_tenancy(tid)

    # Prepay six whole weeks ($3,000) — but only 5 whole + a 3-day boundary are charged.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 300_000,
                 received_on: ~D[2026-02-10],
                 source_payment_id: "p-#{tid}"
               },
               consistency: :strong
             )

    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-12]},
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.status == :terminal
    # 271_429 charged − 300_000 paid = −28_571 → refund owed, signed negative, persists.
    assert proj.final_balance_cents == -28_571
    assert proj.balance_cents == -28_571
  end

  test "an overstay past E appends one overstay charge and settles at the higher balance" do
    tid = "exit-#{System.unique_integer([:positive])}"
    ending_tenancy(tid)

    # E = 02-16; keys returned a full week late (02-23) → one $500 overstay week appended.
    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-23]},
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.status == :terminal
    # Six weeks booked to E ($3,000) + one $500 overstay week − nothing paid = $3,500.
    assert proj.final_balance_cents == 350_000
    assert proj.balance_cents == 350_000
    assert proj.oldest_unpaid_due_date == ~D[2026-01-05]
  end

  test "an overstaying tenant with credit has it consumed first before the residual persists" do
    tid = "exit-#{System.unique_integer([:positive])}"
    ending_tenancy(tid)

    # Prepay $3,200 — a $200 credit over the $3,000 owed at E.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 320_000,
                 received_on: ~D[2026-02-10],
                 source_payment_id: "p-#{tid}"
               },
               consistency: :strong
             )

    # Overstay a full week: the $500 overstay consumes the $200 credit first.
    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-23]},
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.status == :terminal
    # (6 × $500 + $500 overstay) − $3,200 = $300 residual debt (credit absorbed).
    assert proj.final_balance_cents == 30_000
    assert proj.balance_cents == 30_000
  end

  test "an ex-tenant pays down arrears after Terminal — live balance drops, snapshot frozen (P4)" do
    tid = "exit-#{System.unique_integer([:positive])}"
    ending_tenancy(tid)

    # Settle with a $3,000 debt (six weeks booked to E, nothing paid).
    assert :ok =
             CommandedApp.dispatch(
               %C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-16]},
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.status == :terminal
    assert proj.final_balance_cents == 300_000
    assert proj.balance_cents == 300_000

    # Post-Terminal payment of $2,000 — accepted, reduces the live folded balance.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 200_000,
                 received_on: ~D[2026-03-01],
                 source_payment_id: "post-#{tid}"
               },
               consistency: :strong
             )

    proj = projection(tid)
    # Still Terminal (no reopening, no new accrual); live balance drops to $1,000 while
    # the frozen settlement snapshot stays at the $3,000 owed on the keys-return date.
    assert proj.status == :terminal
    assert proj.balance_cents == 100_000
    assert proj.final_balance_cents == 300_000

    # Re-delivering the same source_payment_id is an idempotent no-op (P1).
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 200_000,
                 received_on: ~D[2026-03-01],
                 source_payment_id: "post-#{tid}"
               },
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.balance_cents == 100_000
    assert proj.final_balance_cents == 300_000

    # A further payment that overpays the residual drives the balance negative (credit),
    # without error — the snapshot is still untouched.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 200_000,
                 received_on: ~D[2026-03-08],
                 source_payment_id: "post2-#{tid}"
               },
               consistency: :strong
             )

    proj = projection(tid)
    assert proj.status == :terminal
    assert proj.balance_cents == -100_000
    assert proj.final_balance_cents == 300_000
  end

  test "keys-return is refused on a live tenancy that has no effective end date" do
    tid = "exit-#{System.unique_integer([:positive])}"

    :ok =
      CommandedApp.dispatch(
        %C.CommenceTenancy{
          tenancy_id: tid,
          rent_amount_cents: 50_000,
          cycle: :weekly,
          first_due_date: ~D[2026-01-05]
        },
        consistency: :strong
      )

    assert {:error, :no_effective_end_date} =
             CommandedApp.dispatch(%C.ReturnKeys{tenancy_id: tid, keys_on: ~D[2026-02-16]})
  end
end
