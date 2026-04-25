defmodule AdButlerWeb.Plugs.RequireAuthenticated do
  @moduledoc """
  Plug that enforces authentication on a pipeline.

  Reads `:user_id` from the session, validates it as a UUID, and looks up the
  user. If the user is found it is assigned to `conn.assigns[:current_user]`;
  otherwise the session is dropped and the request is redirected to `/`.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: AdButlerWeb.Endpoint,
    router: AdButlerWeb.Router,
    statics: AdButlerWeb.static_paths()

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> configure_session(drop: true)
        |> redirect(to: ~p"/")
        |> halt()

      user_id ->
        with {:ok, valid_id} <- Ecto.UUID.cast(user_id),
             user when not is_nil(user) <- AdButler.Accounts.get_user(valid_id) do
          assign(conn, :current_user, user)
        else
          _ ->
            conn
            |> configure_session(drop: true)
            |> redirect(to: ~p"/")
            |> halt()
        end
    end
  end
end
