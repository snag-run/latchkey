defmodule LatchkeyWeb.InspectorLedgerPaneTest do
  @moduledoc """
  Tests for the read-only **double-entry ledger pane** (issue #84, spec
  developer-view.md D1, ADR 0006): beside the event log and the fold panes, the
  accounting lens on the same stream — `RentFellDue` as a debit, `RentPaymentRecorded`
  as a credit, running balance = Σ debits − Σ credits, a **reversal rendered as a
  debit** (never a negative credit), and the ledger's final balance shown to equal
  the read-model pane's balance (the same underlying fold).

  Drives the real Postgres `EventStore` (events appended directly, mirroring the
  state-panes test) and asserts on stable DOM ids, never raw HTML. `async: false`
  — the EventStore runs outside the Ecto sandbox, so the shared read connection must
  see the events and the seeded `Arrears` row.
  """
  use LatchkeyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.ArrearsFold
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.RentPaymentRecorded
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced

  setup do
    start_supervised!(Latchkey.EventStore)
    :ok
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  defp put_arrears!(attrs) do
    Arrears
    |> Ash.Changeset.for_create(:upsert, Enum.into(attrs, %{status: :active, balance_cents: 0}))
    |> Ash.create!()
  end

  defp append!(stream_id, events) do
    data =
      events
      |> List.wrap()
      |> Enum.map(fn %mod{} = e ->
        %EventData{event_type: Atom.to_string(mod), data: e, metadata: %{}}
      end)

    :ok = EventStore.append_to_stream(stream_id, :any_version, data)
  end

  # Commence + one weekly charge + one full payment + a reversal of that payment,
  # each on a strictly increasing `occurred_on` so the timeline sort order equals
  # the append order and row indices are deterministic:
  #   0 commenced · 1 rent_fell_due · 2 payment · 3 reversal
  # Folds to: 1 × 50_000 charged − 50_000 paid + 50_000 un-paid by the reversal =
  # 50_000 owing.
  defp seed_stream(stream, tid, pref) do
    append!(stream, [
      %TenancyCommenced{
        tenancy_id: tid,
        property_ref: pref,
        occurred_on: ~D[2026-01-01],
        recorded_on: ~D[2026-01-01],
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-01-01]
      },
      %RentFellDue{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-01],
        recorded_on: ~D[2026-01-01],
        amount_cents: 50_000,
        period_from: ~D[2026-01-01],
        period_to: ~D[2026-01-08]
      },
      %RentPaymentRecorded{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-09],
        recorded_on: ~D[2026-01-09],
        amount_cents: 50_000,
        source_payment_id: "pay-" <> tid
      },
      %RentPaymentRecorded{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-10],
        recorded_on: ~D[2026-01-10],
        amount_cents: -50_000,
        source_payment_id: "rev-" <> tid,
        reason: "dishonoured",
        reverses: "pay-" <> tid
      }
    ])
  end

  describe "tenancy stream ledger pane" do
    setup %{conn: conn} do
      tid = "ledger-" <> uniq()
      stream = "tenancy-" <> tid
      pref = "prop-" <> tid
      seed_stream(stream, tid, pref)

      # The live read model, projected the way production does — via the shared fold
      # — so the ledger's final-balance equivalence has an in-sync row to match.
      derived =
        case EventStore.stream_forward(stream) do
          {:error, :stream_not_found} -> ArrearsFold.fold_and_derive([])
          events -> events |> Enum.map(& &1.data) |> ArrearsFold.fold_and_derive()
        end

      put_arrears!(%{
        tenancy_id: tid,
        status: derived.status,
        balance_cents: derived.balance_cents,
        oldest_unpaid_due_date: derived.oldest_unpaid_due_date,
        final_balance_cents: derived.final_balance_cents
      })

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/#{stream}")
      %{view: view, tid: tid, stream: stream}
    end

    test "renders the ledger pane with debit / credit / balance columns by stable DOM id",
         %{view: view, stream: stream} do
      assert has_element?(view, "#ledger-pane")
      assert has_element?(view, "#ledger-rows")
      # The charge (row 1) is a debit of $500.00 and carries no credit.
      assert has_element?(view, "#ledger-row-#{stream}-1")
      assert has_element?(view, "#ledger-debit-#{stream}-1", "$500.00")
      # The forward payment (row 2) is a credit of $500.00.
      assert has_element?(view, "#ledger-row-#{stream}-2")
      assert has_element?(view, "#ledger-credit-#{stream}-2", "$500.00")
      # Running balance column present on the charge row.
      assert has_element?(view, "#ledger-balance-#{stream}-1")
    end

    test "shows the paid-from / paid-to period on a charge row", %{view: view, stream: stream} do
      assert has_element?(view, "#ledger-period-#{stream}-1", "2026-01-01")
      assert has_element?(view, "#ledger-period-#{stream}-1", "2026-01-08")
    end

    test "a reversal renders as a DEBIT row, never a negative credit", %{
      view: view,
      stream: stream
    } do
      # Row 3 is the reversal (negative RentPaymentRecorded).
      assert has_element?(view, "#ledger-row-#{stream}-3")
      assert has_element?(view, "#ledger-kind-#{stream}-3", "reversal")
      # Re-expanded into the debit column at its positive magnitude (ADR 0006 §7).
      assert has_element?(view, "#ledger-debit-#{stream}-3", "$500.00")
      # And NOT a credit — the credit cell is the empty marker, never "-$500".
      assert has_element?(view, "#ledger-credit-#{stream}-3", "—")
      refute view |> element("#ledger-credit-#{stream}-3") |> render() =~ "500"
    end

    test "ledger final balance matches the read-model pane's balance (same fold)", %{
      view: view
    } do
      # Both are Σ debits − Σ credits over the same events: $500 charged − $500 paid +
      # $500 un-paid by the reversal = $500.00 owing.
      assert has_element?(view, "#read-model-balance", "$500.00")
      assert has_element?(view, "#ledger-final-balance", "$500.00")
      assert has_element?(view, "#ledger-balance-equivalence")
      assert has_element?(view, "#ledger-balance-verdict", "matches")
    end

    test "is read-only — no form, no edit/delete affordance, no 'tamper-evident' claim", %{
      view: view
    } do
      # No mutation controls — the pane is a rendered fold, not an editor.
      refute has_element?(view, "#ledger-pane form")
      refute has_element?(view, "#ledger-pane button")
      assert has_element?(view, "#ledger-caption", "append-only")
      refute view |> element("#ledger-caption") |> render() =~ "tamper-evident"
    end
  end

  describe "accounts edge stream — no ledger pane (D3)" do
    test "renders the event log but no ledger pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")

      assert has_element?(view, "#event-log")
      # The edge folds no state — no aggregate, read-model, or ledger pane.
      refute has_element?(view, "#ledger-pane")
    end
  end
end
