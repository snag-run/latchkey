defmodule LatchkeyWeb.LearnDddLiveTest do
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET /learn/ddd renders the primer", %{conn: conn} do
    conn = get(conn, ~p"/learn/ddd")
    assert conn.status == 200

    {:ok, view, _html} = live(conn)
    assert has_element?(view, "h1.display", "Two contexts, one seam")
  end

  test "the page mounts inside the warm-paper landing scope", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/ddd")

    # reuses the shipped landing/sd-* component scope, not a one-off style
    assert has_element?(view, "div.landing")
    assert has_element?(view, ".topbar")
    assert has_element?(view, ".lk-footer")
  end

  test "each of the four DDD ideas has its own anchored section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/ddd")

    assert has_element?(view, "#contexts")
    assert has_element?(view, "#language")
    assert has_element?(view, "#aggregate")
    assert has_element?(view, "#acl")
  end

  test "teaches with Latchkey's real ubiquitous language and context map", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/learn/ddd")

    # the four DDD concepts, named
    assert html =~ "bounded context"
    assert html =~ "ubiquitous language"
    assert html =~ "aggregate"
    assert html =~ "anti-corruption layer"

    # the real strategic classification from the context map
    assert html =~ "Property Management"
    assert html =~ "Accounts"
    assert html =~ "Core"
    assert html =~ "Supporting"

    # the exact CONTEXT.md ubiquitous-language terms
    assert html =~ "ledger"
    assert html =~ "arrears"
    assert html =~ "property_ref"
    assert html =~ "tenancy"

    # the aggregate + ACL grounded in the real model
    assert html =~ "Tenancy"
    assert html =~ "PaymentReceived"
    assert html =~ "RentPaymentRecorded"
  end

  test "cross-links out to the inspector and its docs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/ddd")

    assert has_element?(view, ~s(a.navlink[href="/inspector"]))
    # nav cross-links to the sibling primer (no in-page heading anchors)
    assert has_element?(view, ~s(a.navlink[href="/learn/event-sourcing"]))
    assert has_element?(view, ~s(a[href="/inspector/docs/context-map"]))
    assert has_element?(view, ~s(a[href="/inspector/docs/domain-model"]))
    assert has_element?(view, ~s(a[href="/inspector/glossary"]))
    assert has_element?(view, ~s(a.lk-btn.primary[href="/inspector"]))
  end
end
