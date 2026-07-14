defmodule LatchkeyWeb.InspectorDocsTest do
  @moduledoc """
  Tests for the in-app **deep docs** (spec glossary.md, D8–D11, issue #131): the
  two `/inspector/docs/{context-map,domain-model}` routes rendering the canonical
  narrative docs, the D9 relative-link→GitHub rewrite, and the D11 front doors
  (the persistent top-bar links + the glossary caption link). Asserts on stable DOM
  ids / hrefs, never raw HTML, per the repo's LiveView testing guidelines.
  """
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  alias LatchkeyWeb.Inspector.Docs

  @github_docs "https://github.com/snag-run/latchkey/blob/main/docs"

  describe "routes + render (D8)" do
    test "the domain-model doc route renders with its section anchors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/docs/domain-model")

      assert has_element?(view, "#docs-page")
      assert has_element?(view, "#docs-content-domain_model")
      # A known section heading anchor (matches the slugs the pane read_more links
      # already carry). Attribute selector — the id begins with a digit.
      assert has_element?(view, "#docs-content-domain_model [id='7-arrears']")
    end

    test "the GFM event tables render as real tables, not raw pipe text", %{conn: conn} do
      # Regression: the MDEx `table` extension must be on, else the domain-model
      # event tables fall through as literal `| Event | … |` paragraphs.
      {:ok, view, _html} = live(conn, ~p"/inspector/docs/domain-model")

      assert has_element?(view, "#docs-content-domain_model table thead th")
      assert has_element?(view, "#docs-content-domain_model table tbody td")
    end

    test "the context-map doc route renders", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/docs/context-map")

      assert has_element?(view, "#docs-page")
      assert has_element?(view, "#docs-content-context_map")
    end
  end

  describe "deep-doc link handling (D9)" do
    test "rewrites a relative doc link to absolute GitHub, leaves absolute links", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/docs/domain-model")

      content = "#docs-content-domain_model"

      # The relative `[ADR 0005](adr/0005-…md)` becomes an absolute GitHub blob URL…
      assert has_element?(
               view,
               "#{content} a[href='#{@github_docs}/adr/0005-simulation-and-time-model.md']"
             )

      # …never a relative href that would 404 in-app under /inspector/docs/…
      refute has_element?(view, "#{content} a[href^='adr/']")
      refute has_element?(view, "#{content} a[href^='/inspector/docs/adr']")

      # An already-absolute external link (NSW RTA) is left untouched.
      assert has_element?(
               view,
               "#{content} a[href='https://www.nsw.gov.au/housing-and-construction/rules/non-payment-of-rent']"
             )
    end

    test "context-map's relative cross-doc link is rewritten to GitHub", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/docs/context-map")

      assert has_element?(
               view,
               "#docs-content-context_map a[href='#{@github_docs}/domain-model.md']"
             )

      refute has_element?(view, "#docs-content-context_map a[href^='./']")
    end
  end

  describe "docs page chrome" do
    test "the top-bar cross-links the reference surfaces; the page keeps its GitHub source link",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/docs/domain-model")

      # Cross-doc navigation is the persistent top-bar, present on every view.
      assert has_element?(view, "#inspector-glossary-link[href='/inspector/glossary']")
      assert has_element?(view, "#inspector-context-map-link[href='/inspector/docs/context-map']")

      assert has_element?(
               view,
               "#inspector-domain-model-link[href='/inspector/docs/domain-model']"
             )

      # The one page-local affordance is the external, new-tab GitHub source (D5c).
      assert has_element?(
               view,
               "#docs-source-link[href='#{@github_docs}/domain-model.md'][target='_blank']"
             )
    end
  end

  describe "discoverability — front doors (D11)" do
    test "the persistent top-bar links to both deep docs and the glossary", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector")

      # The top-bar is the primary front door — present on every view, so the docs
      # are never one missable landing-page pill away.
      assert has_element?(view, "#inspector-glossary-link[href='/inspector/glossary']")
      assert has_element?(view, "#inspector-context-map-link[href='/inspector/docs/context-map']")

      assert has_element?(
               view,
               "#inspector-domain-model-link[href='/inspector/docs/domain-model']"
             )
    end

    test "the glossary domain-lens caption links to the in-app domain model", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/inspector/glossary")

      assert has_element?(
               view,
               "#glossary-domain-model-link[href='/inspector/docs/domain-model']"
             )
    end
  end

  describe "Docs content module" do
    test "docs/0 lists the two deep docs, in canonical order" do
      assert Docs.docs() == [:context_map, :domain_model]
    end

    test "title/1 and source_url/1 resolve per doc" do
      assert Docs.title(:domain_model) == "Domain Model"
      assert Docs.source_url(:context_map) == "#{@github_docs}/context-map.md"
    end
  end
end
