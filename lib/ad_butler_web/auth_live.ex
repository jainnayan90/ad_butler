defmodule AdButlerWeb.AuthLive do
  @moduledoc """
  LiveView lifecycle hooks for authentication.

  Provides `on_mount/4` callbacks that enforce authentication at the LiveView
  layer. Used in `live_session` blocks as defense-in-depth alongside the
  `RequireAuthenticated` plug on the HTTP pipeline.

  The `:require_authenticated` hook reads `user_id` from the session, looks
  up the user via `Accounts.get_user/1`, and assigns `current_user` using
  plain `assign/3` — not `assign_new/3`, which would skip the lookup on a
  reconnected socket and risk serving stale auth state.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias AdButler.Accounts

  @doc """
  Mounts the `:require_authenticated` hook.

  Reads `user_id` from the session. If valid and the user exists, assigns
  `current_user` to the socket and returns `{:cont, socket}`. Otherwise
  redirects to `/` and halts.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    case session["user_id"] do
      nil ->
        {:halt, redirect(socket, to: "/")}

      user_id ->
        with {:ok, valid_id} <- Ecto.UUID.cast(user_id),
             user when not is_nil(user) <- Accounts.get_user(valid_id) do
          {:cont, assign(socket, :current_user, user)}
        else
          _ -> {:halt, redirect(socket, to: "/")}
        end
    end
  end
end
