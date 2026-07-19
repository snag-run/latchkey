defmodule LatchkeyWeb.LearnEventSourcingLiveTest do
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET /learn/event-sourcing returns 200", %{conn: conn} do
    conn = get(conn, ~p"/learn/event-sourcing")
    assert html_response(conn, 200)
  end

  test "the page mounts and shows the primer sections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/event-sourcing")

    assert has_element?(view, "h1.display", "Learn event sourcing on one tenancy.")
    # the warm-paper landing scope is applied (reuses the lk-*/sd-* system)
    assert has_element?(view, "div.landing")

    # the primer beats are reachable anchors
    assert has_element?(view, "#events")
    assert has_element?(view, "#log")
    assert has_element?(view, "#projections")
    assert has_element?(view, "#arrears")
    assert has_element?(view, "#compensation")
    assert has_element?(view, "#replay")

    # reuses the arrears-over-time chart (distinct id/hook from the landing)
    assert has_element?(view, "#es-arrears-timeline")
  end

  test "teaches the real tenancy event vocabulary, scoped to where it lives", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/event-sourcing")

    # the core Property Management (tenancy-stream) events, in the events card
    assert has_element?(view, "#events .evt .name", "TenancyCommenced")
    assert has_element?(view, "#events .evt .name", "RentFellDue")
    assert has_element?(view, "#events .evt .name", "RentPaymentRecorded")
    assert has_element?(view, "#events .evt .name", "TerminationNoticeGiven")

    # PaymentReversed is an Accounts fact (docs/domain-model.md), taught in the
    # compensation section — the tenancy stream never carries it directly
    assert has_element?(view, "#compensation .mono", "PaymentReversed")
    # the reversal lands on the tenancy stream as a signed (negative) RentPaymentRecorded
    assert has_element?(view, "#compensation .evt.appended .name", "RentPaymentRecorded")

    # the replay primitive folds from :origin
    assert has_element?(view, "#replay .mono", ":origin")
  end

  test "the brand links back to the landing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/event-sourcing")

    assert has_element?(view, ~s(a.brand[href="/"]))
  end

  test "cross-links into the inspector and its docs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/learn/event-sourcing")

    assert has_element?(view, ~s(a.navlink[href="/inspector"]))
    # nav cross-links to the sibling primer (no in-page heading anchors)
    assert has_element?(view, ~s(a.navlink[href="/learn/ddd"]))
    assert has_element?(view, ~s(a.lk-btn.primary[href="/inspector"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/docs/domain-model"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/docs/context-map"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/glossary"]))
  end
end
