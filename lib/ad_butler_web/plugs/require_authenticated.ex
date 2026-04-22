defmodule AdButlerWeb.Plugs.RequireAuthenticated do
  @moduledoc false
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
        with {:ok, valid_id} <- Ecto.UUID.cast(user_id),
             user when not is_nil(user) <- AdButler.Accounts.get_user(valid_id) do
          assign(conn, :current_user, user)
        else
          _ ->
            conn
            |> configure_session(drop: true)
            |> redirect(to: "/")
            |> halt()
        end
    end
  end
end
