defmodule LatchkeyWeb.LearnEventSourcingLiveTest do
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET /learn/event-sourcing renders the primer", %{conn: conn} do
    conn = get(conn, ~p"/learn/event-sourcing")
    assert html_response(conn, 200) =~ "Learn event sourcing on one tenancy."
  end

  test "the page mounts and shows the primer sections", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/learn/event-sourcing")

    # hero copy
    assert html =~ "Learn event sourcing on one tenancy."
    # the warm-paper landing scope is applied (reuses the lk-*/sd-* system)
    assert has_element?(view, "div.landing")

    # the six primer beats are reachable anchors
    assert has_element?(view, "#events")
    assert has_element?(view, "#log")
    assert has_element?(view, "#projections")
    assert has_element?(view, "#arrears")
    assert has_element?(view, "#compensation")
    assert has_element?(view, "#replay")

    # reuses the arrears-over-time chart (distinct id/hook from the landing)
    assert has_element?(view, "#es-arrears-timeline")
  end

  test "teaches the real tenancy event vocabulary", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/learn/event-sourcing")

    # the exact event names from docs/domain-model.md
    assert html =~ "TenancyCommenced"
    assert html =~ "RentFellDue"
    assert html =~ "RentPaymentRecorded"
    assert html =~ "PaymentReversed"
    assert html =~ "TerminationNoticeGiven"

    # the real read models and the replay primitive
    assert html =~ "arrears"
    assert html =~ ":origin"
    assert html =~ "14-day gate"
  end

  test "cross-links into the inspector and its docs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/event-sourcing")

    assert has_element?(view, ~s(a.navlink[href="/inspector"]))
    assert has_element?(view, ~s(a.lk-btn.primary[href="/inspector"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/docs/domain-model"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/docs/context-map"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/glossary"]))
  end
end
