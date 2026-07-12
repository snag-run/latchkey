defmodule LatchkeyWeb.InspectorLiveTest do
  @moduledoc """
  Shell-level tests for the read-only `/inspector` LiveView (spec developer-view.md
  D2/D3/D6). Asserts on stable DOM ids, never raw HTML, per the repo's LiveView
  testing guidelines.
  """
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Latchkey.PropertyManagement.Arrears

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

    test "carries a read-more link out to the canonical docs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert view
             |> element("#orientation-map a[href*='context-map.md']")
             |> has_element?()
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

  describe "stream navigation" do
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
  end

  describe "firehose placeholder" do
    test "renders the labelled empty firehose region", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#firehose-placeholder")
    end
  end
end
