defmodule Latchkey.PropertyManagement.TimelineIntegrationTest do
  @moduledoc """
  Seam 2 — command → read through the real Commanded app + Postgres EventStore.
  Dispatches real commands, then reads the compute-on-read timeline and asserts the
  entries it folds from the persisted log, including that the timeline's final
  balance equals the `Arrears` projection (parity). Mirrors
  `TenancyIntegrationTest` (ADR 0003 dispatch-then-assert-read seam).
  """
  use Latchkey.DataCase, async: false

  alias Latchkey.CommandedApp
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Commands, as: C
  alias Latchkey.PropertyManagement.Timeline

  require Ash.Query

  setup do
    start_supervised!(Latchkey.CommandedApp)
    start_supervised!(Latchkey.PropertyManagement.ArrearsProjector)
    :ok
  end

  test "timeline folds the persisted log; final balance matches the Arrears projection" do
    tid = "tl-#{System.unique_integer([:positive])}"

    assert :ok =
             CommandedApp.dispatch(
               %C.CommenceTenancy{
                 tenancy_id: tid,
                 rent_amount_cents: 50_000,
                 cycle: :weekly,
                 first_due_date: ~D[2026-01-05]
               },
               consistency: :strong
             )

    # 28 days behind on 02-02 → notice accepted, sweeping 5 weekly charges + notice.
    assert :ok =
             CommandedApp.dispatch(
               %C.GiveTerminationNotice{
                 tenancy_id: tid,
                 termination_date: ~D[2026-03-01],
                 given_on: ~D[2026-02-02],
                 as_of: ~D[2026-02-02]
               },
               consistency: :strong
             )

    # a payment after the notice (status :ending still accepts payments) — a credit row.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 100_000,
                 received_on: ~D[2026-02-05],
                 source_payment_id: "p-#{tid}"
               },
               consistency: :strong
             )

    entries = Timeline.for_tenancy(tid)

    # 1 commenced + 5 rent_fell_due + 1 notice_given + 1 payment
    assert Enum.map(entries, & &1.kind) == [
             :commenced,
             :rent_fell_due,
             :rent_fell_due,
             :rent_fell_due,
             :rent_fell_due,
             :rent_fell_due,
             :notice_given,
             :payment
           ]

    # the notice row carries the L7 evidence and leaves debit/credit blank
    notice = Enum.find(entries, &(&1.kind == :notice_given))
    assert notice.debit_cents == nil
    assert notice.credit_cents == nil
    assert notice.balance_snapshot_cents == 250_000
    assert notice.days_behind == 28

    # final row's balance == the Arrears projection balance (parity)
    proj = Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()
    assert List.last(entries).balance_snapshot_cents == proj.balance_cents
    assert proj.balance_cents == 150_000
  end

  test "a reversed payment renders as a debit row; the original credit stays; balance restored" do
    tid = "tl-#{System.unique_integer([:positive])}"

    assert :ok =
             CommandedApp.dispatch(
               %C.CommenceTenancy{
                 tenancy_id: tid,
                 rent_amount_cents: 50_000,
                 cycle: :weekly,
                 first_due_date: ~D[2026-01-05]
               },
               consistency: :strong
             )

    # week-1 rent falls due via a catch-up sweep, then the tenant pays it off.
    assert :ok =
             CommandedApp.dispatch(
               %C.CatchUp{tenancy_id: tid, as_of: ~D[2026-01-05]},
               consistency: :strong
             )

    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: tid,
                 amount_cents: 50_000,
                 received_on: ~D[2026-01-10],
                 source_payment_id: "p-#{tid}"
               },
               consistency: :strong
             )

    # the payment dishonours: a negative RentPaymentRecorded at its own reversed date.
    assert :ok =
             CommandedApp.dispatch(
               %C.ReversePayment{
                 tenancy_id: tid,
                 amount_cents: -50_000,
                 reversed_on: ~D[2026-01-20],
                 source_payment_id: "rev-#{tid}",
                 reason: "dishonoured",
                 reverses: "p-#{tid}"
               },
               consistency: :strong
             )

    entries = Timeline.for_tenancy(tid)

    assert Enum.map(entries, & &1.kind) == [:commenced, :rent_fell_due, :payment, :reversal]

    payment = Enum.find(entries, &(&1.kind == :payment))
    reversal = Enum.find(entries, &(&1.kind == :reversal))

    # the original credit is untouched; the reversal re-expands into the debit column
    assert payment.credit_cents == 50_000
    assert payment.debit_cents == nil
    assert reversal.debit_cents == 50_000
    assert reversal.credit_cents == nil
    assert reversal.occurred_on == ~D[2026-01-20]
    assert reversal.reason == "dishonoured"
    assert reversal.reverses == "p-#{tid}"

    # the reversal restores the balance; parity with the Arrears projection holds
    proj = Arrears |> Ash.Query.filter(tenancy_id == ^tid) |> Ash.read_one!()
    assert List.last(entries).balance_snapshot_cents == proj.balance_cents
    assert proj.balance_cents == 50_000
  end

  test "cross-tenancy reallocation: reversal on the wrong tenancy, fresh receipt on the right one" do
    wrong = "tl-wrong-#{System.unique_integer([:positive])}"
    right = "tl-right-#{System.unique_integer([:positive])}"

    for tid <- [wrong, right] do
      assert :ok =
               CommandedApp.dispatch(
                 %C.CommenceTenancy{
                   tenancy_id: tid,
                   rent_amount_cents: 50_000,
                   cycle: :weekly,
                   first_due_date: ~D[2026-01-05]
                 },
                 consistency: :strong
               )

      assert :ok =
               CommandedApp.dispatch(
                 %C.CatchUp{tenancy_id: tid, as_of: ~D[2026-01-05]},
                 consistency: :strong
               )
    end

    # money landed on the WRONG tenancy first.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: wrong,
                 amount_cents: 50_000,
                 received_on: ~D[2026-01-10],
                 source_payment_id: "p-#{wrong}"
               },
               consistency: :strong
             )

    # reallocation = reverse on the wrong tenancy + repost on the right one.
    assert :ok =
             CommandedApp.dispatch(
               %C.ReversePayment{
                 tenancy_id: wrong,
                 amount_cents: -50_000,
                 reversed_on: ~D[2026-01-12],
                 source_payment_id: "rev-#{wrong}",
                 reason: "reallocated to #{right}",
                 reverses: "p-#{wrong}"
               },
               consistency: :strong
             )

    # repost on 01-11 (before the next weekly charge on 01-12) so exactly the one
    # 01-05 charge is on the ledger and the fresh receipt clears it.
    assert :ok =
             CommandedApp.dispatch(
               %C.RecordPayment{
                 tenancy_id: right,
                 amount_cents: 50_000,
                 received_on: ~D[2026-01-11],
                 source_payment_id: "p-#{right}"
               },
               consistency: :strong
             )

    wrong_entries = Timeline.for_tenancy(wrong)
    right_entries = Timeline.for_tenancy(right)

    # the wrong tenancy shows the reversal debit and is back to owing the rent.
    assert Enum.any?(wrong_entries, &(&1.kind == :reversal))
    refute Enum.any?(right_entries, &(&1.kind == :reversal))
    assert List.last(wrong_entries).balance_snapshot_cents == 50_000

    # the right tenancy shows a fresh credit and is cleared.
    fresh = Enum.find(right_entries, &(&1.kind == :payment))
    assert fresh.credit_cents == 50_000
    assert List.last(right_entries).balance_snapshot_cents == 0
  end
end
