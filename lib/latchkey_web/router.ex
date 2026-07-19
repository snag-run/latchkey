defmodule LatchkeyWeb.Router do
  use LatchkeyWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LatchkeyWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LatchkeyWeb do
    pipe_through :browser

    live "/", LandingLive, :index

    # Public, read-only ES/DDD inspector (spec developer-view.md, D6). Deliberately
    # NOT behind the `dev_routes` compile flag below: it is enabled in all envs
    # (incl. prod) so it can serve as a shareable portfolio artifact. It renders
    # domain-event data only — never runtime/system internals (those stay behind
    # the compile-gated LiveDashboard). No auth in v1; no commands, no mutation.
    live_session :inspector do
      live "/inspector", InspectorLive, :landing
      live "/inspector/glossary", InspectorLive, :glossary
      live "/inspector/docs/context-map", InspectorLive, :docs_context_map
      live "/inspector/docs/domain-model", InspectorLive, :docs_domain_model
      live "/inspector/log", InspectorLive, :log
      live "/inspector/streams/:stream_id", InspectorLive, :stream
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", LatchkeyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:latchkey, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: LatchkeyWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
