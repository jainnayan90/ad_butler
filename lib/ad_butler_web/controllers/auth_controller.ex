defmodule AdButlerWeb.AuthController do
  use AdButlerWeb, :controller

  require Logger

  alias AdButler.Accounts
  alias AdButler.ErrorHelpers

  @facebook_oauth_url "https://www.facebook.com/dialog/oauth"

  def request(conn, _params) do
    state = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    app_id = Application.fetch_env!(:ad_butler, :meta_app_id)
    callback_url = Application.fetch_env!(:ad_butler, :meta_oauth_callback_url)

    oauth_url =
      @facebook_oauth_url <>
        "?" <>
        URI.encode_query(%{
          client_id: app_id,
          redirect_uri: callback_url,
          state: state,
          scope: "ads_read,ads_management,email"
        })

    conn
    |> put_session(:oauth_state, {state, System.system_time(:second)})
    |> redirect(external: oauth_url)
  end

  def callback(conn, %{"error" => _error, "error_description" => description}) do
    conn
    |> put_flash(:error, "OAuth error: #{description}")
    |> redirect(to: ~p"/")
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    with {:ok, verified_conn} <- verify_state(conn, state),
         {:ok, user, _conn_record} <- Accounts.authenticate_via_meta(code) do
      Logger.info("OAuth success", user_id: user.id)

      verified_conn
      |> clear_session()
      |> configure_session(renew: true)
      |> put_session(:user_id, user.id)
      |> put_session(:live_socket_id, "users_sessions:#{user.id}")
      |> redirect(to: ~p"/dashboard")
    else
      {:error, :invalid_state, conn} ->
        conn
        |> put_flash(:error, "Invalid OAuth state. Please try again.")
        |> redirect(to: ~p"/")

      {:error, reason} ->
        Logger.error("OAuth failure", reason: ErrorHelpers.safe_reason(reason))

        conn
        |> put_flash(:error, "Authentication failed. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  @state_ttl_seconds 600

  defp verify_state(conn, state) do
    case get_session(conn, :oauth_state) do
      nil ->
        {:error, :invalid_state, delete_session(conn, :oauth_state)}

      {stored_state, issued_at} ->
        cond do
          System.system_time(:second) - issued_at > @state_ttl_seconds ->
            {:error, :invalid_state, delete_session(conn, :oauth_state)}

          not Plug.Crypto.secure_compare(stored_state, state) ->
            {:error, :invalid_state, delete_session(conn, :oauth_state)}

          true ->
            {:ok, delete_session(conn, :oauth_state)}
        end

      _ ->
        {:error, :invalid_state, delete_session(conn, :oauth_state)}
    end
  end

  def logout(conn, _params) do
    user_id = get_session(conn, :user_id)

    if user_id do
      # Disconnect any live sockets for this user
      AdButlerWeb.Endpoint.broadcast("users_sessions:#{user_id}", "disconnect", %{})
    end

    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end
end
