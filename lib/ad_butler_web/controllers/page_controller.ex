defmodule AdButlerWeb.PageController do
  use AdButlerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
