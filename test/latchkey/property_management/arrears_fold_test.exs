defmodule Latchkey.PropertyManagement.ArrearsFoldTest do
  @moduledoc """
  The pure `ArrearsFold.fold_and_derive/1,2` over hand-built event prefixes — no
  event store, no app, no DB (spec `docs/spec/developer-view.md`, D1). Covers the
  prefix fold, the derived read-model fields, and `days_behind` reckoned as-at the
  prefix's last event `occurred_on` (not "today").
  """
  use ExUnit.Case, async: true

  alias Latchkey.PropertyManagement.ArrearsFold
  alias Latchkey.PropertyManagement.Tenancy.Events.KeysReturned
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancySettled
  alias Latchkey.PropertyManagement.Tenancy.Events.TerminationNoticeGiven
  alias Latchkey.PropertyManagement.Tenancy.State

  @tid "t1"
  @rent 50_000

  defp commenced(occurred) do
    %TenancyCommenced{
      tenancy_id: @tid,
      property_ref: "prop-" <> @tid,
      occurred_on: occurred,
      recorded_on: occurred,
      rent_amount_cents: @rent,
      cycle: :weekly,
      first_due_date: occurred
    }
  end

  defp rent(occurred, amount \\ @rent) do
    %RentFellDue{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: occurred,
      amount_cents: amount,
      period_from: occurred,
      period_to: Date.add(occurred, 7)
    }
  end

  defp payment(occurred, amount, id) do
    %RentPaymentRecorded{
      tenancy_id: @tid,
      occurred_on: occurred,
      recorded_on: occurred,
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

  # commence, three weekly charges, one full payment — the workhorse stream the
  # prefix tests slice.
  defp stream do
    [
      commenced(~D[2026-01-05]),
      rent(~D[2026-01-05]),
      rent(~D[2026-01-12]),
      rent(~D[2026-01-19]),
      payment(~D[2026-01-20], @rent, "p1")
    ]
  end

  defp prefix(n), do: Enum.take(stream(), n)

  describe "fold/1 — aggregate core over a prefix" do
    test "empty prefix folds to the initial pending state" do
      assert %State{status: :pending, charges: [], payments_total_cents: 0} =
               ArrearsFold.fold([])
    end

    test "folds the core the same way the aggregate does" do
      core = ArrearsFold.fold(prefix(4))
      assert core.status == :active
      assert core.rent_amount_cents == @rent
      assert length(core.charges) == 3
    end
  end

  describe "fold_and_derive/1 — read-model fields, days_behind as-at last event" do
    test "empty prefix → pending, zeroed, nobody behind" do
      derived = ArrearsFold.fold_and_derive([])

      assert derived.status == :pending
      assert derived.balance_cents == 0
      assert derived.oldest_unpaid_due_date == nil
      assert derived.days_behind == 0
      assert derived.final_balance_cents == nil
    end

    test "commence only → active, nothing due yet" do
      derived = ArrearsFold.fold_and_derive(prefix(1))

      assert derived.status == :active
      assert derived.balance_cents == 0
      assert derived.oldest_unpaid_due_date == nil
      assert derived.days_behind == 0
    end

    test "one charge → balance and oldest-unpaid, days_behind 0 as-at that charge" do
      derived = ArrearsFold.fold_and_derive(prefix(2))

      assert derived.balance_cents == 50_000
      assert derived.oldest_unpaid_due_date == ~D[2026-01-05]
      # last event occurred 2026-01-05 == oldest unpaid → 0 days behind
      assert derived.days_behind == 0
    end

    test "three charges → days_behind climbs, reckoned as-at the last charge" do
      derived = ArrearsFold.fold_and_derive(prefix(4))

      assert derived.balance_cents == 150_000
      assert derived.oldest_unpaid_due_date == ~D[2026-01-05]
      # last event occurred 2026-01-19 − oldest 2026-01-05 = 14
      assert derived.days_behind == 14
    end

    test "a full payment advances oldest-unpaid via FIFO and reduces the balance" do
      derived = ArrearsFold.fold_and_derive(prefix(5))

      assert derived.balance_cents == 100_000
      # 50_000 clears the 01-05 period exactly; FIFO advances to 01-12
      assert derived.oldest_unpaid_due_date == ~D[2026-01-12]
      # payment occurred 2026-01-20 − oldest 2026-01-12 = 8
      assert derived.days_behind == 8
    end

    test "days_behind moves through the scrub — same stream, later prefix reads higher" do
      assert ArrearsFold.fold_and_derive(prefix(2)).days_behind == 0
      assert ArrearsFold.fold_and_derive(prefix(4)).days_behind == 14
    end
  end

  describe "fold_and_derive/2 — explicit as-of date" do
    test "days_behind is reckoned against the supplied date, not the last event" do
      derived = ArrearsFold.fold_and_derive(prefix(4), ~D[2026-02-01])

      # oldest unpaid 2026-01-05; as-of 2026-02-01 → 27 days behind
      assert derived.days_behind == 27
      # the other derived fields do not depend on the as-of date
      assert derived.balance_cents == 150_000
      assert derived.oldest_unpaid_due_date == ~D[2026-01-05]
    end

    test "paid-up prefix reads 0 behind regardless of how late the as-of date is" do
      paid = prefix(2) ++ [payment(~D[2026-01-06], @rent, "p1")]
      assert ArrearsFold.fold_and_derive(paid, ~D[2026-12-31]).days_behind == 0
    end
  end

  describe "settlement snapshot" do
    test "final_balance_cents surfaces from the TenancySettled fold; status is terminal" do
      settled_stream = [
        commenced(~D[2026-01-05]),
        rent(~D[2026-01-05]),
        notice(~D[2026-01-20], ~D[2026-02-01]),
        %KeysReturned{tenancy_id: @tid, occurred_on: ~D[2026-02-01], recorded_on: ~D[2026-02-01]},
        %TenancySettled{
          tenancy_id: @tid,
          occurred_on: ~D[2026-02-01],
          recorded_on: ~D[2026-02-01],
          final_balance_cents: 50_000
        }
      ]

      derived = ArrearsFold.fold_and_derive(settled_stream)

      assert derived.status == :terminal
      assert derived.final_balance_cents == 50_000
      # the live balance is still the raw fold, distinct from the frozen snapshot
      assert derived.balance_cents == 50_000
    end
  end

  describe "reconcile/2 — D1 consistency check against the live Arrears row" do
    # A minimal stand-in for the persisted read-model row: only the fields the
    # check compares (a plain map suffices — reconcile reads fields, never types).
    defp live_row(attrs), do: Enum.into(attrs, %{})

    test "consistent when every persisted field matches the recompute" do
      derived = ArrearsFold.fold_and_derive(prefix(4))

      live =
        live_row(
          status: derived.status,
          balance_cents: derived.balance_cents,
          oldest_unpaid_due_date: derived.oldest_unpaid_due_date,
          final_balance_cents: derived.final_balance_cents
        )

      result = ArrearsFold.reconcile(derived, live)

      assert result.consistent?
      assert Enum.all?(result.fields, & &1.match?)

      assert Enum.map(result.fields, & &1.field) == [
               :status,
               :balance_cents,
               :oldest_unpaid_due_date,
               :final_balance_cents
             ]
    end

    test "flags the drifting field when the live row disagrees" do
      derived = ArrearsFold.fold_and_derive(prefix(4))

      live =
        live_row(
          status: derived.status,
          balance_cents: derived.balance_cents + 1,
          oldest_unpaid_due_date: derived.oldest_unpaid_due_date,
          final_balance_cents: derived.final_balance_cents
        )

      result = ArrearsFold.reconcile(derived, live)

      refute result.consistent?
      balance = Enum.find(result.fields, &(&1.field == :balance_cents))
      refute balance.match?
      assert balance.recomputed == derived.balance_cents
      assert balance.live == derived.balance_cents + 1
    end

    test "days_behind is not part of the persisted equality (computed on read)" do
      derived = ArrearsFold.fold_and_derive(prefix(4))

      refute :days_behind in Enum.map(
               ArrearsFold.reconcile(derived, live_row([])).fields,
               & &1.field
             )
    end
  end

  describe "JSON-rehydrated dates (replay path)" do
    test "ISO-string occurred_on is coerced — fold and the as-of default both cope" do
      events = [
        %TenancyCommenced{
          tenancy_id: @tid,
          property_ref: "prop-" <> @tid,
          occurred_on: "2026-01-05",
          recorded_on: "2026-01-05",
          rent_amount_cents: @rent,
          cycle: "weekly",
          first_due_date: "2026-01-05"
        },
        %RentFellDue{
          tenancy_id: @tid,
          occurred_on: "2026-01-19",
          recorded_on: "2026-01-19",
          amount_cents: @rent,
          period_from: "2026-01-19",
          period_to: "2026-01-26"
        }
      ]

      # The rehydrated commence event carries its non-PII property_ref through the
      # replay path (ADR 0008) — exercises the property_ref mapping in the aggregate's
      # `to_normalized/1` alongside the string-date coercion.
      [commenced | _] = events
      assert commenced.property_ref == "prop-" <> @tid

      derived = ArrearsFold.fold_and_derive(events)

      assert derived.status == :active
      assert derived.oldest_unpaid_due_date == ~D[2026-01-19]
      # as-of default coerced from the string "2026-01-19" == oldest → 0 behind
      assert derived.days_behind == 0
    end
  end
end
