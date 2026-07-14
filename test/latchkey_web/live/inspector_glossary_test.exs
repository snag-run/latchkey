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
    test "the top-bar links to the glossary from any inspector page", %{conn: conn} do
      # The glossary entry-point is the persistent top-bar (present on the landing
      # and every other view), not a landing-page-only pill.
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

    test "toc/0 groups each lens header (level 2) with its term anchors (level 3)" do
      toc = Glossary.toc()

      # Each lens is a level-2 group header whose id jumps to its <section> wrapper.
      assert %{id: "glossary-domain", text: "Domain", level: 2} in toc
      assert %{id: "glossary-ddd", text: "DDD", level: 2} in toc
      # Terms hang off their lens as level-3 entries…
      assert Enum.any?(toc, &(&1.id == "aggregate" and &1.level == 3))

      # …and every term id is an anchor the rendered lenses carry (jump contract),
      # asserted against parsed nodes rather than a raw HTML string.
      rendered =
        Glossary.lenses()
        |> Enum.map_join("\n", &Glossary.html/1)
        |> LazyHTML.from_fragment()

      terms = Enum.filter(toc, &(&1.level == 3))
      refute Enum.empty?(terms)

      assert Enum.all?(terms, fn t ->
               not Enum.empty?(LazyHTML.query(rendered, ~s([id="#{t.id}"])))
             end)
    end
  end

  describe "TOC rail" do
    test "the glossary route swaps the stream nav + firehose for the lens-grouped rail",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      # A lens group header and a term are both jump links in the rail…
      assert has_element?(view, "#toc-rail a[href='#glossary-ddd']")
      assert has_element?(view, "#toc-rail a[href='#aggregate']")
      # …and the stream nav + live firehose are gone on this static reference page.
      refute has_element?(view, "#inspector-nav")
      refute has_element?(view, "#firehose")
    end
  end
end
