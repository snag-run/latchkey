defmodule LatchkeyWeb.InspectorGuidedStreamTest do
  @moduledoc """
  Tests for the deep-stream **numbered fold pipeline + opt-in guided tour**
  (`LatchkeyWeb.Inspector.GuidedStream`): the resting layout renders four numbered
  stages (log → replay → write & read model → ledger); a launcher opts into a
  guided tour whose whole state is `tour_active?` + `tour_step`, driven server-side.

  Drives the real Postgres `EventStore` like the replay-scrubber test and asserts
  on stable DOM ids, never raw HTML. `async: false` — the EventStore runs outside
  the Ecto sandbox, so the shared read connection must see the appended events.
  """
  use LatchkeyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.EventStore
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Events.RentFellDue
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced

  setup do
    start_supervised!(Latchkey.EventStore)
    :ok
  end

  defp uniq, do: Integer.to_string(System.unique_integer([:positive]))

  defp append!(stream_id, events) do
    data =
      events
      |> List.wrap()
      |> Enum.map(fn %mod{} = e ->
        %EventData{event_type: Atom.to_string(mod), data: e, metadata: %{}}
      end)

    :ok = EventStore.append_to_stream(stream_id, :any_version, data)
  end

  defp put_arrears!(attrs) do
    Arrears
    |> Ash.Changeset.for_create(:upsert, Enum.into(attrs, %{status: :active, balance_cents: 0}))
    |> Ash.create!()
  end

  describe "deep stream — numbered fold pipeline" do
    setup %{conn: conn} do
      tid = "tour-" <> uniq()
      stream = "tenancy-" <> tid

      append!(stream, [
        %TenancyCommenced{
          tenancy_id: tid,
          property_ref: "prop-" <> tid,
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
        }
      ])

      put_arrears!(%{tenancy_id: tid, status: :active, balance_cents: 50_000})

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/#{stream}")
      %{view: view, stream: stream}
    end

    test "renders the four numbered pipeline stages and the tour launcher", %{view: view} do
      assert has_element?(view, "#tour-stage-0")
      assert has_element?(view, "#tour-stage-1")
      assert has_element?(view, "#tour-stage-2")
      assert has_element?(view, "#tour-stage-3")
      assert has_element?(view, "#tour-start")
    end

    test "the tour is off by default — no narration card", %{view: view} do
      refute has_element?(view, "#tour-narration")
    end

    test "starting the tour shows the narration card at the first stage", %{view: view} do
      view |> element("#tour-start") |> render_click()

      assert has_element?(view, "#tour-narration")
      assert has_element?(view, "#tour-progress", "1 / 4")
    end

    test "next and back step the tour narration", %{view: view} do
      view |> element("#tour-start") |> render_click()

      view |> element("#tour-next") |> render_click()
      assert has_element?(view, "#tour-progress", "2 / 4")

      view |> element("#tour-back") |> render_click()
      assert has_element?(view, "#tour-progress", "1 / 4")
    end

    test "skipping the tour hides the narration but keeps the pipeline", %{view: view} do
      view |> element("#tour-start") |> render_click()
      assert has_element?(view, "#tour-narration")

      view |> element("#tour-skip") |> render_click()
      refute has_element?(view, "#tour-narration")
      assert has_element?(view, "#tour-stage-0")
    end

    test "the last stage swaps Next for a Done control that exits the tour", %{view: view} do
      view |> element("#tour-start") |> render_click()

      # Four stages: three Next clicks reach the last.
      view |> element("#tour-next") |> render_click()
      view |> element("#tour-next") |> render_click()
      view |> element("#tour-next") |> render_click()

      assert has_element?(view, "#tour-progress", "4 / 4")
      refute has_element?(view, "#tour-next")
      assert has_element?(view, "#tour-done")

      view |> element("#tour-done") |> render_click()
      refute has_element?(view, "#tour-narration")
    end
  end

  describe "accounts edge stream (folds no state — D3)" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/accounts")
      %{view: view}
    end

    test "renders neither the fold pipeline nor the tour launcher", %{view: view} do
      refute has_element?(view, "#tour-stage-0")
      refute has_element?(view, "#tour-start")
    end
  end
end
