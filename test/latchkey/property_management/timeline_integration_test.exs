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
end
