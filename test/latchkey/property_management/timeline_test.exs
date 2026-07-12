defmodule Latchkey.PropertyManagement.TimelineTest do
  @moduledoc """
  Seam 1 — the pure `Timeline.fold/1` over hand-built event lists. No event store,
  no app, no DB. Covers ordering by `(occurred_on, stream_sequence)`, the
  `balance_snapshot`/`days_behind` fold, and the `notice_given` blank debit/credit
  rule (ADR 0006, spec `docs/specs/timeline.md`).
  """
  use ExUnit.Case, async: true

  alias Latchkey.PropertyManagement.Tenancy
  alias Latchkey.PropertyManagement.Tenancy.Aggregate, as: Agg
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven
  alias Latchkey.PropertyManagement.Timeline

  @tid "t1"

  defp commenced(occurred, recorded \\ nil) do
    %TenancyCommenced{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: recorded || occurred,
      rent_amount_cents: 50_000,
      cycle: :weekly,
      first_due_date: occurred
    }
  end

  defp rent(occurred, amount \\ 50_000, recorded \\ nil) do
    %RentFellDue{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: recorded || occurred,
      amount_cents: amount
    }
  end

  defp payment(occurred, amount, id, recorded \\ nil) do
    %RentPaymentRecorded{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: recorded || occurred,
      amount_cents: amount,
      source_payment_id: id
    }
  end

  defp notice(occurred, termination_date) do
    %TerminationNoticeGiven{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: occurred,
      grounds: :arrears,
      termination_date: termination_date
    }
  end

  test "commence-only yields a single opening marker row with zeroed money" do
    [entry] = Timeline.fold([{0, commenced(~D[2026-01-05])}])

    assert entry.kind == :commenced
    assert entry.debit_cents == nil
    assert entry.credit_cents == nil
    assert entry.balance_snapshot_cents == 0
    assert entry.days_behind == 0
    assert entry.occurred_on == ~D[2026-01-05]
    assert entry.recorded_on == ~D[2026-01-05]
  end

  describe "accrual + payment + notice story" do
    # occurred order after sort:
    #   commenced 01-05 (seq 0)
    #   rent      01-05 (seq 1)   +50000 -> 50000
    #   payment   01-10 (seq 3)   -50000 -> 0     (clears week 1)
    #   rent      01-12 (seq 2)   +50000 -> 50000
    #   notice    01-26 (seq 4)           -> 50000, 14 days behind
    #   payment   01-27 (seq 5)   -50000 -> 0     (clears week 2)
    setup do
      events = [
        {0, commenced(~D[2026-01-05])},
        {1, rent(~D[2026-01-05])},
        {2, rent(~D[2026-01-12])},
        {3, payment(~D[2026-01-10], 50_000, "p-1")},
        {4, notice(~D[2026-01-26], ~D[2026-02-20])},
        {5, payment(~D[2026-01-27], 50_000, "p-2")}
      ]

      %{entries: Timeline.fold(events), events: events}
    end

    test "rows come back ordered by (occurred_on, stream_sequence)", %{entries: entries} do
      assert Enum.map(entries, & &1.kind) == [
               :commenced,
               :rent_fell_due,
               :payment,
               :rent_fell_due,
               :notice_given,
               :payment
             ]

      assert Enum.map(entries, & &1.occurred_on) == [
               ~D[2026-01-05],
               ~D[2026-01-05],
               ~D[2026-01-10],
               ~D[2026-01-12],
               ~D[2026-01-26],
               ~D[2026-01-27]
             ]
    end

    test "balance rises then clears, folded in occurred order", %{entries: entries} do
      assert Enum.map(entries, & &1.balance_snapshot_cents) == [
               0,
               50_000,
               0,
               50_000,
               50_000,
               0
             ]
    end

    test "days_behind climbs on the notice row then resets when the week clears", %{
      entries: entries
    } do
      assert Enum.map(entries, & &1.days_behind) == [0, 0, 0, 0, 14, 0]
    end

    test "money rows carry debit/credit; markers leave them blank", %{entries: entries} do
      [_commenced, rent1, pay1, _rent2, notice, _pay2] = entries

      assert {rent1.debit_cents, rent1.credit_cents} == {50_000, nil}
      assert {pay1.debit_cents, pay1.credit_cents} == {nil, 50_000}

      # the notice marker: blank debit/credit but carries the L7 evidence
      assert notice.kind == :notice_given
      assert notice.debit_cents == nil
      assert notice.credit_cents == nil
      assert notice.balance_snapshot_cents == 50_000
      assert notice.days_behind == 14
      assert notice.kick_in_date == ~D[2026-02-20]
    end

    test "final balance equals the Arrears fold (Tenancy.balance_cents)", %{
      entries: entries,
      events: events
    } do
      final = List.last(entries).balance_snapshot_cents

      # fold the same events through the write-side aggregate — the source of the
      # Arrears read model — and assert the timeline's final balance matches it.
      core =
        events
        |> Enum.reduce(%Agg{}, fn {_seq, event}, agg -> Agg.apply(agg, event) end)
        |> Map.fetch!(:core)

      assert final == Tenancy.balance_cents(core)
      assert final == 0
    end
  end

  test "days_behind is pinned to the canonical Tenancy.days_behind/2 (drift guard)" do
    # Events already in (occurred_on, stream_sequence) order, so the aggregate's
    # charge accumulation matches the timeline's occurred-order fold. No payments,
    # so the final (notice) row is a meaningful non-zero arrears case.
    events = [
      {0, commenced(~D[2026-01-05])},
      {1, rent(~D[2026-01-05])},
      {2, rent(~D[2026-01-12])},
      {3, rent(~D[2026-01-19])},
      {4, notice(~D[2026-02-02], ~D[2026-03-01])}
    ]

    entries = Timeline.fold(events)
    last = List.last(entries)

    # The final row folds every event, so its as-at state == the full core state.
    # Pin the timeline's local FIFO copy to the canonical fold — if the Tenancy
    # days_behind semantics change (CORE lane), this fails instead of drifting.
    core =
      events
      |> Enum.reduce(%Agg{}, fn {_seq, event}, agg -> Agg.apply(agg, event) end)
      |> Map.fetch!(:core)

    assert last.days_behind == Tenancy.days_behind(core, last.occurred_on)
    assert last.days_behind > 0
  end

  test "a late-booked (lazy accrual) tick sorts at its occurred_on, recorded_on shown" do
    # rent fell due 01-12 but was swept/booked on 02-01 (recorded lags occurred).
    events = [
      {0, commenced(~D[2026-01-05])},
      {1, rent(~D[2026-01-05], 50_000, ~D[2026-01-05])},
      {2, rent(~D[2026-01-12], 50_000, ~D[2026-02-01])}
    ]

    entries = Timeline.fold(events)
    late = List.last(entries)

    assert late.kind == :rent_fell_due
    assert late.occurred_on == ~D[2026-01-12]
    # both dates are present so the render layer can mute recorded_on only when equal
    assert late.recorded_on == ~D[2026-02-01]
    refute late.recorded_on == late.occurred_on
  end

  test "same-day events break the tie by stream_sequence, keeping the balance reproducible" do
    # two charges and a payment all on 01-05; sequence decides the fold order.
    events = [
      {0, commenced(~D[2026-01-05])},
      {2, payment(~D[2026-01-05], 50_000, "p-1")},
      {1, rent(~D[2026-01-05])},
      {3, rent(~D[2026-01-05])}
    ]

    entries = Timeline.fold(events)

    assert Enum.map(entries, & &1.kind) == [:commenced, :rent_fell_due, :payment, :rent_fell_due]
    assert Enum.map(entries, & &1.balance_snapshot_cents) == [0, 50_000, 0, 50_000]
  end
end
