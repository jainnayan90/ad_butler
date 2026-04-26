defmodule AdButlerWeb.DevLoginController do
  @moduledoc """
  Dev-only bypass for Meta OAuth. Creates (or reuses) a seed user and writes
  a session directly — no browser redirect to Facebook required.

  Only compiled when `config :ad_butler, dev_routes: true` (dev env).
  This module and its route never exist in production builds.
  """

  use AdButlerWeb, :controller

  alias AdButler.Accounts

  @dev_user %{
    meta_user_id: "100000000000001",
    email: "dev@localhost",
    name: "Dev User"
  }

  @doc "Creates or reuses the dev seed user and opens an authenticated session."
  def login(conn, _params) do
    {:ok, user} = Accounts.create_or_update_user(@dev_user)

    conn
    |> clear_session()
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:live_socket_id, "users_sessions:#{user.id}")
    |> redirect(to: ~p"/dashboard")
  end
end
