defmodule AdButlerWeb.PageController do
  @moduledoc """
  Controller for top-level HTML pages: the public home page and the authenticated
  dashboard.
  """

  use AdButlerWeb, :controller

  @doc "Renders the public home page."
  def home(conn, _params) do
    render(conn, :home)
  end

  @doc "Renders the authenticated user dashboard."
  def dashboard(conn, _params) do
    render(conn, :dashboard)
  end
end
