defmodule AdButlerWeb.Plugs.RequireAuthenticated do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> configure_session(drop: true)
        |> redirect(to: "/")
        |> halt()

      user_id ->
        case AdButler.Accounts.get_user(user_id) do
          nil ->
            conn
            |> configure_session(drop: true)
            |> redirect(to: "/")
            |> halt()

          user ->
            assign(conn, :current_user, user)
        end
    end
  end
end
