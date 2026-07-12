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
