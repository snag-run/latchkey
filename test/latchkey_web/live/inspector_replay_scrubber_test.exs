defmodule LatchkeyWeb.InspectorReplayScrubberTest do
  @moduledoc """
  Tests for the **server-side replay scrubber** (issue #85, spec developer-view.md
  decision **D4**): the tenancy stream-detail view's centerpiece — watch the four
  panes fold event-by-event over a selected prefix `[0..k]`, computed by the same
  shared fold (`ArrearsFold` / `Timeline.fold`) production runs, entirely server-side.

  Drives the real Postgres `EventStore` (events appended directly, mirroring the
  fold-pane test) and asserts on stable DOM ids, never raw HTML. `async: false` —
  the EventStore runs outside the Ecto sandbox, so the shared read connection must
  see the events and the seeded `Arrears` row.
  """
  use LatchkeyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
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

  # A 4-event stream whose arrears deliberately climb then fall through the scrub:
  #   k=1  commence only        → $0.00,    0 days behind
  #   k=2  + one charge         → $500.00,  0 days behind (as-at 2026-01-01)
  #   k=3  + second charge      → $1000.00, 7 days behind (as-at 2026-01-08)
  #   k=4  + full payment       → $0.00,    0 days behind (paid off)
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
        occurred_on: ~D[2026-01-30],
        recorded_on: ~D[2026-01-30],
        amount_cents: 100_000,
        source_payment_id: "pay-" <> tid
      }
    ])
  end

  describe "tenancy stream — replay scrubber (D4)" do
    setup %{conn: conn} do
      tid = "scrub-" <> uniq()
      stream = "tenancy-" <> tid
      pref = "prop-" <> tid
      seed_stream(stream, tid, pref)

      # A live read-model row so the consistency check has something to reconcile
      # against at the head; the scrubber never writes it back.
      put_arrears!(%{tenancy_id: tid, status: :active, balance_cents: 0})

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/#{stream}")
      %{view: view, tid: tid, stream: stream}
    end

    test "renders the filmstrip controls by stable DOM id, opening at the head", %{
      view: view
    } do
      assert has_element?(view, "#replay-scrubber")
      assert has_element?(view, "#filmstrip-frames")
      assert has_element?(view, "#scrubber-start")
      assert has_element?(view, "#scrubber-step-back")
      assert has_element?(view, "#scrubber-step-forward")
      assert has_element?(view, "#scrubber-play-toggle")
      # Opens at the head: k = N = 4.
      assert has_element?(view, "#scrubber-position", "4 / 4")
    end

    test "at the head the last event is highlighted and panes read the full history", %{
      view: view,
      stream: stream
    } do
      assert has_element?(view, "#event-row-#{stream}-4[aria-current]")
      # Full history: both charges paid off.
      assert has_element?(view, "#read-model-balance", "$0.00")
      assert has_element?(view, "#read-model-days-behind", "0 days")
    end

    test "step-back re-folds the prefix and moves the highlight", %{view: view, stream: stream} do
      view |> element("#scrubber-step-back") |> render_click()

      assert has_element?(view, "#scrubber-position", "3 / 4")
      # Prefix [0..3]: two charges, unpaid — balance climbs, arrears appear.
      assert has_element?(view, "#read-model-balance", "$1000.00")
      assert has_element?(view, "#read-model-days-behind", "7 days")
      # Highlight moved to event 3; event 4 is no longer current.
      assert has_element?(view, "#event-row-#{stream}-3[aria-current]")
      refute has_element?(view, "#event-row-#{stream}-4[aria-current]")
    end

    test "clicking a frame scrubs to an arbitrary prefix, recomputing all panes server-side", %{
      view: view,
      stream: stream
    } do
      view |> element("#event-row-#{stream}-2") |> render_click()

      assert has_element?(view, "#scrubber-position", "2 / 4")
      # Prefix [0..2]: one charge, not yet late.
      assert has_element?(view, "#read-model-balance", "$500.00")
      assert has_element?(view, "#read-model-days-behind", "0 days")
      assert has_element?(view, "#event-row-#{stream}-2[aria-current]")
      # The ledger pane recomputes over the same prefix: commence + one charge =
      # rows 0 and 1; the second charge (row 2) is not yet folded in.
      assert has_element?(view, "#ledger-row-#{stream}-1")
      refute has_element?(view, "#ledger-row-#{stream}-2")
    end

    test "arrears visibly climb and fall across the scrub (days_behind as-at event k)", %{
      view: view,
      stream: stream
    } do
      view |> element("#event-row-#{stream}-2") |> render_click()
      assert has_element?(view, "#read-model-days-behind", "0 days")

      view |> element("#event-row-#{stream}-3") |> render_click()
      assert has_element?(view, "#read-model-days-behind", "7 days")

      view |> element("#event-row-#{stream}-4") |> render_click()
      assert has_element?(view, "#read-model-days-behind", "0 days")
    end

    test "the empty prefix (k=0) folds to nothing and highlights no event", %{
      view: view,
      stream: stream
    } do
      view |> element("#scrubber-start") |> render_click()

      assert has_element?(view, "#scrubber-position", "0 / 4")
      assert has_element?(view, "#read-model-balance", "$0.00")
      refute has_element?(view, "[aria-current]")
      # No ledger rows at the empty prefix.
      refute has_element?(view, "#ledger-row-#{stream}-0")
    end

    test "step-forward advances toward the head", %{view: view, stream: stream} do
      view |> element("#event-row-#{stream}-1") |> render_click()
      assert has_element?(view, "#scrubber-position", "1 / 4")

      view |> element("#scrubber-step-forward") |> render_click()
      assert has_element?(view, "#scrubber-position", "2 / 4")
    end

    test "play toggles the server-side auto-advance and each tick folds one more event", %{
      view: view
    } do
      # Play from the head rewinds to the empty prefix for a full replay.
      view |> element("#scrubber-play-toggle") |> render_click()
      assert has_element?(view, "#scrubber-play-toggle[aria-pressed='true']")
      assert has_element?(view, "#scrubber-position", "0 / 4")

      # Each server-side tick advances one event (driven by hand in test).
      send(view.pid, :scrubber_tick)
      assert has_element?(view, "#scrubber-position", "1 / 4")

      send(view.pid, :scrubber_tick)
      assert has_element?(view, "#scrubber-position", "2 / 4")
    end

    test "auto-advance halts at the head and clears the playing state", %{
      view: view,
      stream: stream
    } do
      view |> element("#event-row-#{stream}-3") |> render_click()
      # Resume play from k=3.
      view |> element("#scrubber-play-toggle") |> render_click()
      assert has_element?(view, "#scrubber-play-toggle[aria-pressed='true']")

      # One tick reaches the head (k=4) and auto-pauses.
      send(view.pid, :scrubber_tick)
      assert has_element?(view, "#scrubber-position", "4 / 4")
      assert has_element?(view, "#scrubber-play-toggle[aria-pressed='false']")

      # A stale tick after halting is inert (does not advance past the head).
      send(view.pid, :scrubber_tick)
      assert has_element?(view, "#scrubber-position", "4 / 4")
    end

    test "pause cancels auto-advance so a later tick does not advance", %{
      view: view,
      stream: stream
    } do
      view |> element("#event-row-#{stream}-1") |> render_click()
      view |> element("#scrubber-play-toggle") |> render_click()
      # Pause.
      view |> element("#scrubber-play-toggle") |> render_click()
      assert has_element?(view, "#scrubber-play-toggle[aria-pressed='false']")

      send(view.pid, :scrubber_tick)
      # Paused: the inert tick leaves the position untouched.
      assert has_element?(view, "#scrubber-position", "1 / 4")
    end

    test "the scrubber is read-only — no form, no 'tamper-evident' claim", %{view: view} do
      refute has_element?(view, "form")
      assert has_element?(view, "#scrubber-caption", "append-only")
      refute view |> element("#scrubber-caption") |> render() =~ "tamper-evident"
    end
  end

  describe "accounts edge stream — no scrubber (D3/D4)" do
    test "the events-only edge view carries no replay scrubber", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")

      assert has_element?(view, "#event-log")
      refute has_element?(view, "#replay-scrubber")
      refute has_element?(view, "#filmstrip-frames")
    end
  end
end
