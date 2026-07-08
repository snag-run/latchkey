defmodule LatchkeyWeb.PageController do
  use LatchkeyWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
