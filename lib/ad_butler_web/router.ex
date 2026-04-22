defmodule AdButlerWeb.Router do
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

    get "/dashboard", PageController, :dashboard
  end

  pipeline :rate_limited do
    plug AdButlerWeb.PlugAttack
  end

  pipeline :health_check do
    # Intentionally empty: no PlugAttack here. Fly probers share IPs and
    # would trigger the rate limit, causing machine restart loops.
    # The PlugAttack health rule below is kept for future per-IP limiting.
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
    end
  end
end
