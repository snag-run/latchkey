defmodule LatchkeyWeb.LandingLiveTest do
  use LatchkeyWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / renders the landing as the front door (no longer redirects to /inspector)", %{
    conn: conn
  } do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Every fact of a tenancy"
  end

  test "the page mounts and shows the narrative sections", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # hero copy
    assert html =~ "Every fact of a tenancy, in the order it happened."
    # the warm-paper landing scope is applied
    assert has_element?(view, "div.landing")
    # append-only correction beat: the Accounts PaymentReversed fact is named,
    # and on the tenancy stream it lands as a signed (negative) RentPaymentRecorded
    assert html =~ "PaymentReversed"
    assert has_element?(view, ".corr .evt.appended .name", "RentPaymentRecorded")
    # write vs read seam + arrears timeline anchors exist
    assert has_element?(view, "#seam")
    assert has_element?(view, "#timeline")
    assert has_element?(view, "#arrears-timeline")
    # names the learning-project framing (ES + DDD practice)
    assert has_element?(view, "#about")
    assert html =~ "learning project"
    assert html =~ "event sourcing and domain-driven design"
  end

  test "calls-to-action point into the inspector", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s(a.navlink[href="/inspector"]))
    assert has_element?(view, ~s(a.lk-btn.primary[href="/inspector"]))
    assert has_element?(view, ~s(a.lk-btn.ghost[href="/inspector/docs/domain-model"]))
  end

  test "cross-links to the learn primers from the nav and the about section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # discoverable in the top nav
    assert has_element?(view, ~s(a.navlink[href="/learn/event-sourcing"]))
    assert has_element?(view, ~s(a.navlink[href="/learn/ddd"]))
    # and again, in context, from the about section
    assert has_element?(view, ~s(#about a.lk-btn[href="/learn/event-sourcing"]))
    assert has_element?(view, ~s(#about a.lk-btn[href="/learn/ddd"]))
  end

  test "the wordmark links home", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s(a.brand[href="/"]))
  end

  test "footer carries the byline and project links", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "David Taing"
    assert has_element?(view, ~s(.lk-footer a[href="https://snag.run"]))
    assert has_element?(view, ~s(.lk-footer a[href="https://github.com/snag-run/latchkey"]))
  end
end
