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
    # append-only correction beat uses the real event name
    assert html =~ "PaymentReversed"
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

  test "footer carries the byline and project links", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "David Taing"
    assert has_element?(view, ~s(.lk-footer a[href="https://snag.run"]))
    assert has_element?(view, ~s(.lk-footer a[href="https://github.com/snag-run/latchkey"]))
  end
end
