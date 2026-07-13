defmodule LatchkeyWeb.PageControllerTest do
  use LatchkeyWeb.ConnCase

  test "GET / redirects to the inspector (the app's front door for now)", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/inspector"
  end
end
