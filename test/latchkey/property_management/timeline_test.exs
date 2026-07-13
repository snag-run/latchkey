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
  alias Latchkey.PropertyManagement.Tenancy.Events.KeysReturned
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancySettled
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven
  alias Latchkey.PropertyManagement.Timeline

  @tid "t1"

  defp commenced(occurred, recorded \\ nil) do
    %TenancyCommenced{
      tenancy_id: @tid,
      property_ref: "prop-" <> @tid,
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

  defp reversal(occurred, amount, id, opts) do
    %RentPaymentRecorded{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: Keyword.get(opts, :recorded, occurred),
      amount_cents: amount,
      source_payment_id: id,
      reason: Keyword.get(opts, :reason),
      reverses: Keyword.get(opts, :reverses)
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

  # A `RentFellDue` carrying an explicit half-open `[period_from, period_to)` span —
  # what the exit boundary/overstay charges emit (#31/#32), distinct from a whole
  # weekly period.
  defp rent_span(occurred, amount, period_from, period_to) do
    %RentFellDue{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: occurred,
      amount_cents: amount,
      period_from: period_from,
      period_to: period_to
    }
  end

  defp keys_returned(occurred, recorded \\ nil) do
    %KeysReturned{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: recorded || occurred
    }
  end

  defp settled(occurred, final_balance_cents) do
    %TenancySettled{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: occurred,
      final_balance_cents: final_balance_cents
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

  test "a whole monthly charge renders its real period span, not a hardcoded 7 days" do
    # A monthly RentFellDue carries a full calendar-month span (ADR 0009). The timeline
    # must read `[period_from, period_to)` straight off the event — a 31-day January
    # period, not a 7-day week — so the exhibit states the real month length.
    events = [
      {0, commenced(~D[2026-01-15])},
      {1, rent_span(~D[2026-01-15], 200_000, ~D[2026-01-15], ~D[2026-02-15])}
    ]

    charge = Enum.find(Timeline.fold(events), &(&1.kind == :rent_fell_due))

    assert charge.period_from == ~D[2026-01-15]
    assert charge.period_to == ~D[2026-02-15]
    # 31 days, read from the event — decisively not the legacy `Date.add(due, 7)` guess.
    assert Date.diff(charge.period_to, charge.period_from) == 31
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

  describe "reversal rendering (ADR 0006 §7)" do
    # week-1 rent falls due, the tenant pays, then the payment dishonours and is
    # reversed. The reversal is a NEGATIVE RentPaymentRecorded at its own reversed_on.
    #   commenced 01-05 (seq 0)          -> 0
    #   rent      01-05 (seq 1)  +50000  -> 50000
    #   payment   01-10 (seq 2)  -50000  -> 0        (clears the week)
    #   reversal  01-20 (seq 3)  +50000  -> 50000    (undoes the payment)
    setup do
      events = [
        {0, commenced(~D[2026-01-05])},
        {1, rent(~D[2026-01-05])},
        {2, payment(~D[2026-01-10], 50_000, "p-1")},
        {3, reversal(~D[2026-01-20], -50_000, "rev-1", reason: "dishonoured", reverses: "p-1")}
      ]

      %{entries: Timeline.fold(events)}
    end

    test "a negative payment renders as a reversal DEBIT row at its own occurred_on", %{
      entries: entries
    } do
      rev = List.last(entries)

      assert rev.kind == :reversal
      assert rev.occurred_on == ~D[2026-01-20]
      # re-expanded into the debit column — never shown as a negative credit
      assert rev.debit_cents == 50_000
      assert rev.credit_cents == nil
    end

    test "the reversal restores the running balance", %{entries: entries} do
      assert Enum.map(entries, & &1.balance_snapshot_cents) == [0, 50_000, 0, 50_000]
    end

    test "the original payment credit row is left untouched", %{entries: entries} do
      payment = Enum.find(entries, &(&1.kind == :payment))

      assert payment.occurred_on == ~D[2026-01-10]
      assert payment.credit_cents == 50_000
      assert payment.debit_cents == nil
      # exactly one credit row and one debit reversal row — nothing was mutated/hidden
      assert Enum.count(entries, &(&1.kind == :payment)) == 1
      assert Enum.count(entries, &(&1.kind == :reversal)) == 1
    end

    test "the reversal surfaces its reason and the payment it reverses", %{entries: entries} do
      rev = List.last(entries)

      assert rev.reason == "dishonoured"
      assert rev.reverses == "p-1"
      assert rev.description =~ "dishonoured"
    end

    test "days_behind climbs again once the payment is undone", %{entries: entries} do
      # paid-up on the payment row, back 15 days behind (01-20 − 01-05) on the reversal
      assert Enum.map(entries, & &1.days_behind) == [0, 0, 0, 15]
    end
  end

  test "a reversal with no reason degrades to a bare 'Payment reversed' description" do
    events = [
      {0, commenced(~D[2026-01-05])},
      {1, rent(~D[2026-01-05])},
      {2, payment(~D[2026-01-10], 50_000, "p-1")},
      {3, reversal(~D[2026-01-20], -50_000, "rev-1", reverses: "p-1")}
    ]

    rev = List.last(Timeline.fold(events))

    assert rev.kind == :reversal
    assert rev.reason == nil
    assert rev.description == "Payment reversed"
  end

  describe "exit & terminal rows (#50)" do
    # A weekly $700 tenancy runs out its arrears, is noticed to end mid-week at
    # E = 01-29, then keys are returned on E. Accrual books three whole weeks, the
    # boundary period [01-26, 01-29) is pro-rated (3/7 × $700 = $300), and settlement
    # freezes the reckoning. Occurred-order after sort:
    #   commenced 01-05 (seq 0)               -> 0
    #   rent      01-05 (seq 1)  +70000       -> 70000
    #   rent      01-12 (seq 2)  +70000       -> 140000
    #   rent      01-19 (seq 3)  +70000       -> 210000
    #   notice    01-19 (seq 4)               -> 210000, E = 01-29
    #   rent      01-26 (seq 5)  +30000       -> 240000   (boundary [01-26, 01-29))
    #   keys      01-29 (seq 6)               -> 240000
    #   settled   01-29 (seq 7)               -> 240000   (= final reckoning, debt)
    setup do
      events = [
        {0, commenced(~D[2026-01-05])},
        {1, rent(~D[2026-01-05], 70_000)},
        {2, rent(~D[2026-01-12], 70_000)},
        {3, rent(~D[2026-01-19], 70_000)},
        {4, notice(~D[2026-01-19], ~D[2026-01-29])},
        {5, rent_span(~D[2026-01-26], 30_000, ~D[2026-01-26], ~D[2026-01-29])},
        {6, keys_returned(~D[2026-01-29])},
        {7, settled(~D[2026-01-29], 240_000)}
      ]

      %{entries: Timeline.fold(events)}
    end

    test "rows interleave the exit markers by occurred_on", %{entries: entries} do
      assert Enum.map(entries, & &1.kind) == [
               :commenced,
               :rent_fell_due,
               :rent_fell_due,
               :rent_fell_due,
               :notice_given,
               :rent_fell_due,
               :keys_returned,
               :settled
             ]
    end

    test "keys-returned is a dated marker with blank money", %{entries: entries} do
      keys = Enum.find(entries, &(&1.kind == :keys_returned))

      assert keys.occurred_on == ~D[2026-01-29]
      assert keys.debit_cents == nil
      assert keys.credit_cents == nil
      assert keys.description =~ "Keys returned"
    end

    test "the boundary charge is an ordinary debit row carrying its own period", %{
      entries: entries
    } do
      # the 4th rent charge — the pro-rated boundary week
      boundary = Enum.find(entries, &(&1.occurred_on == ~D[2026-01-26]))

      assert boundary.kind == :rent_fell_due
      assert boundary.debit_cents == 30_000
      assert boundary.credit_cents == nil
      # its span is the true half-open [01-26, 01-29), NOT a hardcoded whole week
      assert boundary.period_from == ~D[2026-01-26]
      assert boundary.period_to == ~D[2026-01-29]
    end

    test "settlement is the punchline: its snapshot IS the final reckoning (debt)", %{
      entries: entries
    } do
      settled = List.last(entries)

      assert settled.kind == :settled
      assert settled.debit_cents == nil
      assert settled.credit_cents == nil
      # the settlement figure is exactly the folded balance snapshot (no separate field)
      assert settled.balance_snapshot_cents == 240_000
      assert settled.description =~ "final balance"
      assert settled.description =~ "$2,400.00"
      assert settled.description =~ "owing"
    end
  end

  test "a prepaid exit settles to a refund owed (negative snapshot), signed refund" do
    # tenant overpays, then exits: settlement snapshot is negative — a refund owed.
    #   commenced 01-05          -> 0
    #   rent      01-05  +50000  -> 50000
    #   payment   01-06  -80000  -> -30000  (overpaid)
    #   keys      01-10          -> -30000
    #   settled   01-10          -> -30000  (refund owed)
    events = [
      {0, commenced(~D[2026-01-05])},
      {1, rent(~D[2026-01-05])},
      {2, payment(~D[2026-01-06], 80_000, "p-1")},
      {3, keys_returned(~D[2026-01-10])},
      {4, settled(~D[2026-01-10], -30_000)}
    ]

    settled = List.last(Timeline.fold(events))

    assert settled.kind == :settled
    assert settled.balance_snapshot_cents == -30_000
    assert settled.description =~ "$300.00"
    assert settled.description =~ "refund owed"
  end

  test "a post-terminal (P4) payment is a credit row below settlement; the settlement row is unchanged" do
    # after settlement froze a $500 debt, an ex-tenant pays it down. The payment is an
    # ordinary credit row BELOW the settlement row and moves the running balance; the
    # settlement snapshot itself never changes.
    #   commenced 01-05          -> 0
    #   rent      01-05  +50000  -> 50000
    #   keys      01-10          -> 50000
    #   settled   01-10          -> 50000  (debt frozen)
    #   payment   01-15  -50000  -> 0      (P4 — below settlement)
    events = [
      {0, commenced(~D[2026-01-05])},
      {1, rent(~D[2026-01-05])},
      {2, keys_returned(~D[2026-01-10])},
      {3, settled(~D[2026-01-10], 50_000)},
      {4, payment(~D[2026-01-15], 50_000, "p4-1")}
    ]

    entries = Timeline.fold(events)
    settled = Enum.find(entries, &(&1.kind == :settled))
    p4 = List.last(entries)

    # the settlement row is immutable history — still the frozen $500 debt
    assert settled.balance_snapshot_cents == 50_000

    # the P4 payment sorts below settlement and moves the running balance to zero
    assert p4.kind == :payment
    assert p4.credit_cents == 50_000
    assert p4.balance_snapshot_cents == 0

    assert Enum.find_index(entries, &(&1.kind == :settled)) <
             Enum.find_index(entries, &(&1 == p4))
  end

  test "the settlement row renders the FOLDED balance, ignoring the event's final_balance_cents" do
    # Guards the "no separate final-balance field to drift" contract (ADR 0006 §5):
    # `normalize/1` drops `TenancySettled.final_balance_cents`, and the punchline is
    # derived purely from the running fold. Here the stored field is deliberately bogus
    # ($9,999.99) while the fold reckons a $500 debt — the render must follow the fold.
    #   commenced 01-05          -> 0
    #   rent      01-05  +50000  -> 50000  (the true folded reckoning)
    #   keys      01-10          -> 50000
    #   settled   01-10          -> 50000  (final_balance_cents lies: 999_999)
    events = [
      {0, commenced(~D[2026-01-05])},
      {1, rent(~D[2026-01-05])},
      {2, keys_returned(~D[2026-01-10])},
      {3, settled(~D[2026-01-10], 999_999)}
    ]

    settled = List.last(Timeline.fold(events))

    assert settled.kind == :settled
    # follows the fold, NOT the event's stored (divergent) final_balance_cents
    assert settled.balance_snapshot_cents == 50_000
    assert settled.description =~ "$500.00"
    assert settled.description =~ "owing"
    refute settled.description =~ "9,999.99"
  end
end
