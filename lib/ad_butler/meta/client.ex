defmodule AdButler.Meta.Client do
  @moduledoc false
  @behaviour AdButler.Meta.ClientBehaviour

  require Logger

  @graph_api_base "https://graph.facebook.com/v19.0"
  @rate_limit_table :meta_rate_limits
  @meta_long_lived_token_ttl_seconds 60 * 24 * 60 * 60

  @impl true
  @spec list_ad_accounts(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_ad_accounts(access_token) do
    make_request(:get, "#{@graph_api_base}/me/adaccounts",
      params: [
        access_token: access_token,
        fields: "id,name,currency,timezone_name,account_status"
      ]
    )
  end

  @impl true
  @spec list_campaigns(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_campaigns(ad_account_id, access_token, opts \\ []) do
    make_request(:get, "#{@graph_api_base}/#{ad_account_id}/campaigns",
      params: Keyword.merge([access_token: access_token], opts),
      ad_account_id: ad_account_id
    )
  end

  @impl true
  @spec list_ad_sets(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_ad_sets(ad_account_id, access_token, opts \\ []) do
    make_request(:get, "#{@graph_api_base}/#{ad_account_id}/adsets",
      params: Keyword.merge([access_token: access_token], opts),
      ad_account_id: ad_account_id
    )
  end

  @impl true
  @spec list_ads(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_ads(ad_account_id, access_token, opts \\ []) do
    make_request(:get, "#{@graph_api_base}/#{ad_account_id}/ads",
      params: Keyword.merge([access_token: access_token], opts),
      ad_account_id: ad_account_id
    )
  end

  @impl true
  @spec get_creative(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get_creative(creative_id, access_token) do
    case Req.request(
           req_options() ++
             [
               method: :get,
               url: "#{@graph_api_base}/#{creative_id}",
               params: [access_token: access_token]
             ]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, handle_error(resp)}
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec batch_request(String.t(), list(map())) :: {:ok, list(map())} | {:error, term()}
  def batch_request(access_token, requests) do
    case Req.request(
           req_options() ++
             [
               method: :post,
               url: @graph_api_base,
               form: [access_token: access_token, batch: Jason.encode!(requests)]
             ]
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, resp} -> {:error, handle_error(resp)}
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec get_rate_limit_usage(String.t()) :: float()
  def get_rate_limit_usage(ad_account_id) do
    case :ets.lookup(@rate_limit_table, ad_account_id) do
      [{_, {call_count, _cpu_time, _total_time, _ts}}] -> call_count / 100.0
      [] -> 0.0
    end
  end

  @impl true
  @spec refresh_token(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_token(access_token) do
    app_id = Application.fetch_env!(:ad_butler, :meta_app_id)
    app_secret = Application.fetch_env!(:ad_butler, :meta_app_secret)

    case Req.request(
           req_options() ++
             [
               method: :get,
               url: "#{@graph_api_base}/oauth/access_token",
               params: [
                 grant_type: "fb_exchange_token",
                 client_id: app_id,
                 client_secret: app_secret,
                 fb_exchange_token: access_token
               ]
             ]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, handle_error(resp)}
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec exchange_code(String.t()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer()}} | {:error, term()}
  def exchange_code(code) do
    app_id = Application.fetch_env!(:ad_butler, :meta_app_id)
    app_secret = Application.fetch_env!(:ad_butler, :meta_app_secret)
    callback_url = Application.fetch_env!(:ad_butler, :meta_oauth_callback_url)

    case Req.post(
           "#{@graph_api_base}/oauth/access_token",
           req_options() ++
             [
               form: [
                 client_id: app_id,
                 client_secret: app_secret,
                 redirect_uri: callback_url,
                 code: code
               ]
             ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        expires_in =
          case Map.fetch(body, "expires_in") do
            {:ok, val} ->
              val

            :error ->
              Logger.warning("Meta token exchange did not return expires_in, using default TTL")
              @meta_long_lived_token_ttl_seconds
          end

        {:ok, %{access_token: token, expires_in: expires_in}}

      {:ok, %{body: body}} when is_map(body) ->
        safe = %{
          code: get_in(body, ["error", "code"]),
          type: get_in(body, ["error", "type"]),
          subcode: get_in(body, ["error", "error_subcode"])
        }

        {:error, {:token_exchange_failed, safe}}

      {:ok, %{status: status}} ->
        {:error, {:token_exchange_failed, %{code: nil, type: nil, subcode: nil, status: status}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  @spec get_me(String.t()) :: {:ok, map()} | {:error, term()}
  def get_me(access_token) do
    case Req.get(
           "#{@graph_api_base}/me",
           req_options() ++
             [params: [fields: "id,name,email", access_token: access_token]]
         ) do
      {:ok, %{status: 200, body: %{"id" => id} = body}} ->
        {:ok,
         %{
           email: body["email"],
           name: body["name"],
           meta_user_id: id
         }}

      {:ok, %{body: body}} ->
        {:error, {:user_info_failed, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req_options, do: Application.get_env(:ad_butler, :req_options, [])

  defp make_request(method, url, opts) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, [])
    ad_account_id = Keyword.get(opts, :ad_account_id)

    case Req.request(
           req_options() ++ [method: method, url: url, headers: headers, params: params]
         ) do
      {:ok, %{status: 200, body: %{"data" => data}} = resp} ->
        parse_rate_limit_header(resp, ad_account_id)
        {:ok, data}

      {:ok, %{status: 200, body: body} = resp} ->
        parse_rate_limit_header(resp, ad_account_id)
        {:ok, body}

      {:ok, resp} ->
        {:error, handle_error(resp)}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_error(%{status: 400, body: %{"error" => %{"message" => msg}}}),
    do: {:bad_request, msg}

  defp handle_error(%{status: 400}), do: {:bad_request, "Bad request"}
  defp handle_error(%{status: 401}), do: :unauthorized
  defp handle_error(%{status: 403}), do: :forbidden
  defp handle_error(%{status: 429}), do: :rate_limit_exceeded
  defp handle_error(%{status: status}) when status >= 500, do: :meta_server_error
  defp handle_error(_), do: :unknown_error

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp parse_rate_limit_header(%{headers: headers}, ad_account_id)
       when is_binary(ad_account_id) do
    raw =
      cond do
        is_map(headers) ->
          headers["x-business-use-case-usage"]

        is_list(headers) ->
          case List.keyfind(headers, "x-business-use-case-usage", 0) do
            {_, value} -> value
            nil -> nil
          end

        true ->
          nil
      end

    raw_json =
      case raw do
        [json | _] when is_binary(json) -> json
        json when is_binary(json) -> json
        _ -> nil
      end

    case raw_json do
      nil ->
        :ok

      json ->
        with {:ok, decoded} <- Jason.decode(json),
             [{_key, [%{"call_count" => cc, "cpu_time" => cpu, "total_time" => total}]}] <-
               Enum.take(decoded, 1) do
          :ets.insert(@rate_limit_table, {ad_account_id, {cc, cpu, total, DateTime.utc_now()}})
        else
          _ -> :ok
        end
    end
  end

  defp parse_rate_limit_header(_, _), do: :ok

  @doc "Returns the configured Meta API client module (injectable for testing)."
  def client, do: Application.get_env(:ad_butler, :meta_client, __MODULE__)
end
