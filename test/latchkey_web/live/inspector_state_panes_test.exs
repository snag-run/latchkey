defmodule LatchkeyWeb.InspectorStatePanesTest do
  @moduledoc """
  Tests for the read-only **aggregate-state + read-model panes** (issue #83, spec
  developer-view.md D1/D2): beside the event log, the folded `%Tenancy.State{}` core
  and the derived `Arrears` fields, plus the D1 consistency check that the full-prefix
  recompute equals the live `Arrears` row.

  Drives the real Postgres `EventStore` (events appended directly, mirroring the
  event-log pane test) and asserts on stable DOM ids, never raw HTML. `async: false`
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

  # commence + two weekly charges + one full payment. Folds to: active, balance
  # 50_000 (2 × 50_000 charged − 50_000 paid), oldest-unpaid advanced by FIFO.
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
      %RentFellDue{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-08],
        recorded_on: ~D[2026-01-08],
        amount_cents: 50_000,
        period_from: ~D[2026-01-08],
        period_to: ~D[2026-01-15]
      },
      %RentPaymentRecorded{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-09],
        recorded_on: ~D[2026-01-09],
        amount_cents: 50_000,
        source_payment_id: "pay-" <> tid
      }
    ])
  end

  describe "tenancy stream fold panes" do
    setup %{conn: conn} do
      tid = "panes-" <> uniq()
      stream = "tenancy-" <> tid
      pref = "prop-" <> tid
      seed_stream(stream, tid, pref)

      # The live read model, projected the same way production does — via the shared
      # fold — so the consistency check has an in-sync row to reconcile against.
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

    test "renders the aggregate-state pane with core fields by stable DOM id", %{view: view} do
      assert has_element?(view, "#fold-panes")
      assert has_element?(view, "#aggregate-state-pane")
      assert has_element?(view, "#aggregate-status", "active")
      assert has_element?(view, "#aggregate-due-through")
      assert has_element?(view, "#aggregate-charges")
      assert has_element?(view, "#aggregate-effective-end-date")
      # A write-model caption distinguishing it, linking the canonical aggregate doc.
      assert has_element?(view, "#aggregate-caption")
      assert view |> element("#aggregate-caption a[href*='domain-model.md']") |> has_element?()
    end

    test "renders the read-model pane with derived Arrears fields by stable DOM id", %{view: view} do
      assert has_element?(view, "#read-model-pane")
      assert has_element?(view, "#read-model-status", "active")
      # balance = 2 × $500 charged − $500 paid = $500.00
      assert has_element?(view, "#read-model-balance", "$500.00")
      assert has_element?(view, "#read-model-oldest-unpaid")
      assert has_element?(view, "#read-model-days-behind")
      # A read-model caption distinguishing it, linking the canonical arrears doc.
      assert has_element?(view, "#read-model-caption")
      assert view |> element("#read-model-caption a[href*='domain-model.md']") |> has_element?()
    end

    test "consistency check reconciles the recompute against the live Arrears row", %{view: view} do
      assert has_element?(view, "#consistency-check")
      # Seeded to match the fold → in sync, every persisted field equal.
      assert has_element?(view, "#consistency-verdict", "in sync")
      assert has_element?(view, "#consistency-field-status")
      assert has_element?(view, "#consistency-field-balance_cents")
      assert has_element?(view, "#consistency-field-oldest_unpaid_due_date")
      assert has_element?(view, "#consistency-field-final_balance_cents")
    end

    test "consistency check flags a drifted live row honestly", %{
      view: view,
      tid: tid,
      conn: conn
    } do
      # Corrupt only the live read-model row (never the log) — the recompute stays
      # truthful and the check must surface the drift.
      put_arrears!(%{tenancy_id: tid, status: :active, balance_cents: 999_999})

      stream = "tenancy-" <> tid
      {:ok, view2, _html} = live(conn, ~p"/inspector/streams/#{stream}")

      assert has_element?(view2, "#consistency-verdict", "drifted")
      # sanity: the untouched view was in sync before the corruption
      assert has_element?(view, "#consistency-verdict", "in sync")
    end

    test "is read-only — no form, no edit/delete affordance, no 'tamper-evident' claim", %{
      view: view
    } do
      refute has_element?(view, "form")
      assert has_element?(view, "#consistency-caption", "append-only")
      refute render(view) =~ "tamper-evident"
    end
  end

  describe "accounts edge stream — no fold panes (D3)" do
    test "renders the event log but no aggregate/read-model panes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")

      assert has_element?(view, "#event-log")
      # The edge folds no aggregate state — the absence of these panes is the point.
      refute has_element?(view, "#fold-panes")
      refute has_element?(view, "#aggregate-state-pane")
      refute has_element?(view, "#read-model-pane")
    end
  end
end
