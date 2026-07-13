defmodule LatchkeyWeb.PageController do
  use LatchkeyWeb, :controller

  # The inspector is the app's front door for now (a dedicated landing page comes
  # later); send the root straight there.
  def home(conn, _params) do
    redirect(conn, to: ~p"/inspector")
  end
end
