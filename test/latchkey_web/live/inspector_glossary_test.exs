defmodule LatchkeyWeb.InspectorGlossaryTest do
  @moduledoc """
  Tests for the in-app glossary (spec glossary.md, D1/D2/D3/D6): the
  `/inspector/glossary` route, its three lens-sections rendered from markdown with
  per-term heading anchors, the domain lens wired verbatim to `CONTEXT.md`, and the
  landing entry-point link. Asserts on stable DOM ids / hrefs, never raw HTML, per
  the repo's LiveView testing guidelines.
  """
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias LatchkeyWeb.Inspector.Glossary

  describe "route + render" do
    test "/inspector/glossary is reachable and public", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(view, "#glossary")
    end

    test "renders the three lens-sections", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(view, "#glossary-domain")
      assert has_element?(view, "#glossary-ddd")
      assert has_element?(view, "#glossary-es")
    end

    test "is read-only — no mutating form on the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      refute has_element?(view, "#glossary form")
    end
  end

  describe "per-term heading anchors (deep-link targets)" do
    test "a known domain term carries its fragment anchor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      # "## Rental ledger" in CONTEXT.md → #rental-ledger.
      assert has_element?(view, "#rental-ledger")
    end

    test "a DDD heading and an ES heading carry fragment anchors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(view, "#glossary-ddd #aggregate")
      assert has_element?(view, "#glossary-es #projection-vs-compute-on-read")
    end

    test "anchor/1 output resolves to a rendered heading id (deep-link contract)", %{conn: conn} do
      # The slug a pane read_more will point at (#129) must be a real anchor on the
      # page — asserted against the rendered DOM, not the HTML string.
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(view, "#" <> Glossary.anchor("Rental ledger"))
    end
  end

  describe "DDD/ES entry anchors (spec D5 a+b+c)" do
    test "the confirmed seed-set headings render in each lens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      for anchor <- ~w(aggregate bounded-context anti-corruption-layer domain-event command) do
        assert has_element?(view, "#glossary-ddd ##{anchor}")
      end

      for anchor <- ~w(event-store--stream event-vs-command fold--evolve replay immutability) do
        assert has_element?(view, "#glossary-es ##{anchor}")
      end
    end

    test "at least one entry links to a live inspector surface (anchor b)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      # The live-surface link points into the running inspector at a stable seeded
      # stream — the anchoring payoff (concept seen live).
      assert has_element?(
               view,
               "#glossary a[href*='/inspector/streams/tenancy-notice-then-paid']"
             )
    end

    test "entries link out to their source on GitHub (anchor c)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(view, "#glossary a[href*='github.com/snag-run/latchkey/blob/main']")
    end
  end

  describe "domain lens wired to CONTEXT.md (D1/D6)" do
    test "renders the domain framing caption", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(view, "#glossary-domain-framing")
    end

    test "renders a term from CONTEXT.md (guards render-not-copy)", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      # The anchor id is derived from the live CONTEXT.md heading; if the domain lens
      # stopped rendering the file, this target would vanish.
      assert has_element?(view, "#glossary-domain #directory")
    end
  end

  describe "discoverability (D3)" do
    test "the orientation landing shows the glossary entry-point link", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(
               view,
               "#orientation-glossary-link[href='/inspector/glossary']"
             )
    end

    test "the workbench header links to the glossary from any inspector page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      assert has_element?(view, "#inspector-glossary-link[href='/inspector/glossary']")
    end
  end

  describe "Glossary content module" do
    test "lenses/0 lists the three lenses, domain first" do
      assert Glossary.lenses() == [:domain, :ddd, :es]
    end

    test "anchor/1 produces a GitHub-style slug" do
      assert Glossary.anchor("Rental ledger") == "rental-ledger"
    end

    test "each lens renders headings" do
      for lens <- Glossary.lenses() do
        headings =
          lens
          |> Glossary.html()
          |> LazyHTML.from_fragment()
          |> LazyHTML.filter("h1, h2")

        refute Enum.empty?(headings)
      end
    end
  end
end
