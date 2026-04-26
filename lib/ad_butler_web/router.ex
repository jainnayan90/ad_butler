defmodule AdButlerWeb.Router do
  @moduledoc """
  Phoenix router for AdButlerWeb.

  Pipelines:
  - `:browser` — HTML requests with CSRF, session, and a strict CSP header.
  - `:authenticated` — requires a valid session via `RequireAuthenticated`.
  - `:rate_limited` — applies `PlugAttack` throttling (OAuth routes).
  - `:health_check` — intentionally empty; see inline comment for why PlugAttack
    is excluded here.
  """

  use AdButlerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AdButlerWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; img-src 'self' data:; font-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'self'; object-src 'none'"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :authenticated do
    plug AdButlerWeb.Plugs.RequireAuthenticated
  end

  pipeline :health_check do
    # Intentionally empty: no PlugAttack here. Fly probers share IPs and
    # would trigger the rate limit, causing machine restart loops.
    # The PlugAttack health rule below is kept for future per-IP limiting.
  end

  pipeline :rate_limited do
    plug AdButlerWeb.PlugAttack
  end

  scope "/health", AdButlerWeb do
    pipe_through :health_check

    get "/liveness", HealthController, :liveness
    get "/readiness", HealthController, :readiness
  end

  scope "/", AdButlerWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  scope "/", AdButlerWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      layout: {AdButlerWeb.Layouts, :app},
      on_mount: {AdButlerWeb.AuthLive, :require_authenticated} do
      live "/connections", ConnectionsLive
      live "/ad-accounts", DashboardLive
      live "/campaigns", CampaignsLive
      live "/ad-sets", AdSetsLive
      live "/ads", AdsLive
    end

    get "/dashboard", AuthController, :dashboard_redirect
  end

  scope "/auth", AdButlerWeb do
    pipe_through [:browser, :rate_limited]

    get "/meta", AuthController, :request
    get "/meta/callback", AuthController, :callback
    delete "/logout", AuthController, :logout
  end

  # Other scopes may use custom stacks.
  # scope "/api", AdButlerWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ad_butler, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AdButlerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
      get "/login", AdButlerWeb.DevLoginController, :login
    end
  end
end
