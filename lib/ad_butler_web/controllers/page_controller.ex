defmodule AdButlerWeb.PageController do
  @moduledoc """
  Controller for top-level HTML pages: the public home page.

  The authenticated dashboard is served by `AdButlerWeb.DashboardLive`.
  """

  use AdButlerWeb, :controller

  @doc "Renders the public home page."
  def home(conn, _params) do
    render(conn, :home)
  end
end
