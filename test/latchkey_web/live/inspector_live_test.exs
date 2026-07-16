defmodule LatchkeyWeb.InspectorLiveTest do
  @moduledoc """
  Shell-level tests for the read-only `/inspector` LiveView (spec developer-view.md
  D2/D3/D6). Asserts on stable DOM ids, never raw HTML, per the repo's LiveView
  testing guidelines.
  """
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias EventStore.EventData
  alias Latchkey.EventStore
  alias Latchkey.Inspector.Broadcaster
  alias Latchkey.PropertyManagement.Arrears
  alias Latchkey.PropertyManagement.Tenancy.Events.TenancyCommenced

  # Insert an Arrears read-model row directly (fast, no event replay) so the nav
  # has live tenancy streams to list.
  defp put_arrears!(attrs) do
    Arrears
    |> Ash.Changeset.for_create(:upsert, Enum.into(attrs, %{status: :active, balance_cents: 0}))
    |> Ash.create!()
  end

  describe "route" do
    test "/inspector is reachable, public and renders the shell", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#inspector")
      assert has_element?(view, "#inspector-nav")
      assert has_element?(view, "#orientation-map")
    end

    test "the shell is read-only — no mutating form on the landing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      refute has_element?(view, "form")
    end
  end

  describe "orientation-map landing" do
    test "renders both live context boxes and the named-only boxes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#orientation-map")
      assert has_element?(view, "#ctx-box-tenancy")
      assert has_element?(view, "#ctx-box-accounts")

      for slug <- ~w(maintenance inspections compliance leasing business-development) do
        assert has_element?(view, "#named-box-#{slug}")
      end
    end

    test "renders the ACL-1 seam edge with the language-flip label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#acl-1-edge", "payment → arrears reduction")
    end

    test "carries a read-more link to the in-app context-map doc", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      # #129/D10: the orientation-map read_more targets the in-app context-map page
      # (top), same-tab — no github.com, no target=_blank. Pin by the read_more's
      # "context-map.md" text so the sibling D11 reference-nav link (same href, but
      # labelled "Context Map") can't satisfy this in its place.
      assert has_element?(
               view,
               "#orientation-map a[href='/inspector/docs/context-map']:not([target='_blank'])",
               "context-map.md"
             )
    end
  end

  describe "nav rail" do
    test "renders the deep and edge contexts, the aggregate and the accounts stream", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#nav-context-tenancy")
      assert has_element?(view, "#nav-context-accounts")
      assert has_element?(view, "#nav-aggregate-tenancy")
      assert has_element?(view, "#nav-stream-accounts")
      assert has_element?(view, "#nav-named-only")
      assert has_element?(view, "#nav-named-maintenance")
    end

    test "lists the seeded tenancy streams by stable DOM id", %{conn: conn} do
      put_arrears!(%{tenancy_id: "paid-up", status: :active})
      put_arrears!(%{tenancy_id: "arrears-no-notice", status: :active, balance_cents: 150_000})

      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#nav-stream-tenancy-paid-up")
      assert has_element?(view, "#nav-stream-tenancy-arrears-no-notice")
      # and they appear as clickable streams on the map too
      assert has_element?(view, "#map-stream-tenancy-paid-up")
    end
  end

  describe "nav rail scenario grouping" do
    # Enough of two scenarios to form multi-member groups, plus a lone scenario
    # that should fall into the shared "other" bucket.
    defp seed_scenarios! do
      for n <- 1..3, do: put_arrears!(%{tenancy_id: "arrears-0#{n}", balance_cents: 100_000})
      for n <- 1..2, do: put_arrears!(%{tenancy_id: "healthy-0#{n}"})
      put_arrears!(%{tenancy_id: "paid-up"})
    end

    test "fans streams into collapsible scenario groups with counts", %{conn: conn} do
      seed_scenarios!()

      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#nav-group-arrears", "Arrears")
      assert has_element?(view, "#nav-group-healthy", "Healthy")
      # the lone scenario is bucketed, not a count-1 group of its own
      assert has_element?(view, "#nav-group-other", "Other")
      refute has_element?(view, "#nav-group-paid-up")
      # every stream is still in the DOM (collapse only hides), addressable directly
      assert has_element?(view, "#nav-stream-tenancy-arrears-01")
      assert has_element?(view, "#nav-stream-tenancy-paid-up")
    end

    test "toggling a group expands it (chevron rotates)", %{conn: conn} do
      seed_scenarios!()

      {:ok, view, _html} = live(conn, ~p"/inspector")

      # collapsed by default
      refute has_element?(view, "#nav-group-arrears .rotate-90")

      view |> element("#nav-group-arrears button") |> render_click()
      assert has_element?(view, "#nav-group-arrears .rotate-90")

      # toggling again collapses
      view |> element("#nav-group-arrears button") |> render_click()
      refute has_element?(view, "#nav-group-arrears .rotate-90")
    end

    test "filtering hides non-matching streams and reveals matches", %{conn: conn} do
      seed_scenarios!()

      {:ok, view, _html} = live(conn, ~p"/inspector")

      view |> element("#nav-filter") |> render_keyup(%{"value" => "arrears-01"})

      # the match is shown, a non-match is hidden (class toggled, still in DOM)
      refute has_element?(view, "#nav-stream-tenancy-arrears-01.hidden")
      assert has_element?(view, "#nav-stream-tenancy-healthy-01.hidden")
    end

    test "a no-match filter surfaces an honest empty state", %{conn: conn} do
      seed_scenarios!()

      {:ok, view, _html} = live(conn, ~p"/inspector")

      view |> element("#nav-filter") |> render_keyup(%{"value" => "zzz-nope"})

      assert has_element?(view, "#nav-no-match-tenancy", "no streams match")
    end
  end

  describe "stream navigation" do
    # The stream view now renders the event-log pane (#81), which reads the raw
    # EventStore; start it (Commanded is disabled in :test).
    setup do
      start_supervised!(Latchkey.EventStore)
      :ok
    end

    test "selecting a stream from the nav routes to the stream view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      view |> element("#nav-stream-accounts") |> render_click()

      assert has_element?(view, "#stream-view")
      assert has_element?(view, "#stream-view-accounts")
      assert has_element?(view, "#inspector-breadcrumb")
    end

    test "a tenancy stream URL renders its placeholder view directly", %{conn: conn} do
      put_arrears!(%{tenancy_id: "paid-up", status: :active})

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/tenancy-paid-up")

      assert has_element?(view, "#stream-view-tenancy-paid-up")
      # nav marks it active
      assert has_element?(view, "#nav-stream-tenancy-paid-up.bg-primary\\/10")
    end

    test "an unknown stream id surfaces not-found, not a defaulted context", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/streams/does-not-exist")

      assert has_element?(view, "#stream-not-found")
      # it must NOT masquerade as a valid stream/context view
      refute has_element?(view, "#stream-view")
      refute has_element?(view, "#inspector-breadcrumb")
    end

    test "deep-linking into a stream auto-expands its nav group", %{conn: conn} do
      put_arrears!(%{tenancy_id: "arrears-01", balance_cents: 100_000})
      put_arrears!(%{tenancy_id: "arrears-02", balance_cents: 100_000})
      put_arrears!(%{tenancy_id: "healthy-01"})
      put_arrears!(%{tenancy_id: "healthy-02"})

      {:ok, view, _html} = live(conn, ~p"/inspector/streams/tenancy-arrears-01")

      # the active stream's group opens; an unrelated group stays collapsed
      assert has_element?(view, "#nav-group-arrears .rotate-90")
      refute has_element?(view, "#nav-group-healthy .rotate-90")
    end
  end

  describe "firehose feed" do
    defp broadcast_dev_event!(event, metadata) do
      Phoenix.PubSub.broadcast(
        Latchkey.PubSub,
        Broadcaster.global_topic(),
        {:dev_event, event, metadata}
      )
    end

    test "renders the empty feed region on mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#firehose-feed")
    end

    test "a broadcast dev_event appends a new row, labelled by event type + stream id",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      event = %TenancyCommenced{
        tenancy_id: "firehose-demo",
        occurred_on: ~D[2026-07-13],
        recorded_on: ~D[2026-07-13],
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-07-20]
      }

      metadata = %{
        event_number: 1,
        stream_id: "tenancy-firehose-demo",
        stream_version: 1,
        created_at: ~U[2026-07-13 10:00:00Z]
      }

      broadcast_dev_event!(event, metadata)

      assert has_element?(view, "#firehose-1")
      assert has_element?(view, "#firehose-1", "TenancyCommenced")
      assert has_element?(view, "#firehose-1", "tenancy-firehose-demo")
    end

    test "each row is clickable and carries its stream_id/position (click-to-scrub is structural only, #86)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      event = %TenancyCommenced{
        tenancy_id: "firehose-demo",
        occurred_on: ~D[2026-07-13],
        recorded_on: ~D[2026-07-13],
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-07-20]
      }

      metadata = %{
        event_number: 1,
        stream_id: "tenancy-firehose-demo",
        stream_version: 1,
        created_at: ~U[2026-07-13 10:00:00Z]
      }

      broadcast_dev_event!(event, metadata)

      assert has_element?(
               view,
               "#firehose-1[phx-value-stream_id='tenancy-firehose-demo'][phx-value-position='1']"
             )

      # clicking acknowledges structurally — it does not crash or navigate, since
      # the stream-detail view it will eventually scrub to doesn't exist yet (#86)
      view |> element("#firehose-1") |> render_click()
      assert has_element?(view, "#inspector")
    end
  end

  describe "firehose backlog on mount" do
    # The backlog reads the real EventStore (Commanded is disabled in :test); start it
    # here so mount pre-populates today's events. The store is shared/accumulating, so
    # assertions target the specific global event number this test appended.
    setup do
      start_supervised!(Latchkey.EventStore)
      :ok
    end

    defp append_commenced!(stream_id, %mod{} = event) do
      data = [%EventData{event_type: Atom.to_string(mod), data: event, metadata: %{}}]
      :ok = EventStore.append_to_stream(stream_id, :any_version, data)

      {:ok, events} = EventStore.read_all_streams_backward(-1, 5_000)

      events
      |> Enum.find(&(&1.stream_uuid == stream_id))
      |> Map.fetch!(:event_number)
    end

    test "today's already-recorded events pre-populate the feed on mount", %{conn: conn} do
      tid = "backlog-#{System.unique_integer([:positive])}"
      stream = "tenancy-" <> tid

      event = %TenancyCommenced{
        tenancy_id: tid,
        occurred_on: ~D[2026-01-01],
        recorded_on: ~D[2026-01-01],
        rent_amount_cents: 50_000,
        cycle: :weekly,
        first_due_date: ~D[2026-01-08]
      }

      n = append_commenced!(stream, event)

      {:ok, view, _html} = live(conn, ~p"/inspector")

      # The just-appended event (recorded today, at the store head) lands as a row
      # without any live broadcast.
      assert has_element?(view, "#firehose-#{n}", "TenancyCommenced")
      assert has_element?(view, "#firehose-#{n}", stream)
    end
  end
end
