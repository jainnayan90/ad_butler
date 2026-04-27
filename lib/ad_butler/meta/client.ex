defmodule AdButler.Meta.Client do
  @moduledoc """
  HTTP client for the Meta (Facebook) Graph API v23.0.

  Implements `AdButler.Meta.ClientBehaviour` so the module can be swapped out
  with a mock in tests via `Application.put_env(:ad_butler, :meta_client, ...)`.
  Rate-limit usage per ad account is tracked in an ETS table managed by
  `AdButler.Meta.RateLimitStore` and is readable via `get_rate_limit_usage/1`.
  """
  @behaviour AdButler.Meta.ClientBehaviour

  require Logger

  @graph_api_base "https://graph.facebook.com/v23.0"
  @rate_limit_table :meta_rate_limits
  @meta_long_lived_token_ttl_seconds 60 * 24 * 60 * 60

  @impl true
  @spec list_ad_accounts(String.t()) :: {:ok, list(map())} | {:error, term()}
  def list_ad_accounts(access_token) do
    make_request(:get, "#{@graph_api_base}/me/adaccounts",
      params: [fields: "id,name,currency,timezone_name,account_status"],
      headers: auth_header(access_token)
    )
  end

  @impl true
  @spec list_campaigns(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_campaigns(ad_account_id, access_token, opts \\ []) do
    make_request(:get, "#{@graph_api_base}/#{ad_account_id}/campaigns",
      params: opts,
      headers: auth_header(access_token),
      ad_account_id: ad_account_id
    )
  end

  @impl true
  @spec list_ad_sets(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_ad_sets(ad_account_id, access_token, opts \\ []) do
    make_request(:get, "#{@graph_api_base}/#{ad_account_id}/adsets",
      params: opts,
      headers: auth_header(access_token),
      ad_account_id: ad_account_id
    )
  end

  @impl true
  @spec list_ads(String.t(), String.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list_ads(ad_account_id, access_token, opts \\ []) do
    make_request(:get, "#{@graph_api_base}/#{ad_account_id}/ads",
      params: opts,
      headers: auth_header(access_token),
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
               headers: auth_header(access_token)
             ]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, handle_error(%{resp | body: decode_body(resp.body)})}
      {:error, %{reason: :timeout}} -> {:error, :timeout}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  @spec batch_request(String.t(), list(map())) :: {:ok, list(map())} | {:error, term()}
  def batch_request(access_token, requests) do
    # Meta Batch API requires the token as a POST body field — Bearer header not accepted here.
    case Req.request(
           req_options() ++
             [
               method: :post,
               url: @graph_api_base,
               form: [access_token: access_token, batch: Jason.encode!(requests)]
             ]
         ) do
      {:ok, %{status: 200, body: body}} when is_list(body) -> {:ok, body}
      {:ok, resp} -> {:error, handle_error(%{resp | body: decode_body(resp.body)})}
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
               method: :post,
               url: "#{@graph_api_base}/oauth/access_token",
               form: [
                 grant_type: "fb_exchange_token",
                 client_id: app_id,
                 client_secret: app_secret,
                 fb_exchange_token: access_token
               ]
             ]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, resp} -> {:error, handle_error(%{resp | body: decode_body(resp.body)})}
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
             [params: [fields: "id,name,email"], headers: auth_header(access_token)]
         ) do
      {:ok, %{status: 200, body: body}} ->
        parsed = if is_binary(body), do: Jason.decode!(body), else: body

        case parsed do
          %{"id" => id} ->
            {:ok, %{name: parsed["name"], email: parsed["email"], meta_user_id: id}}

          _ ->
            {:error, {:user_info_failed, parsed}}
        end

      {:ok, %{body: body}} ->
        {:error, {:user_info_failed, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp auth_header(token), do: [{"authorization", "Bearer #{token}"}]

  defp req_options, do: Application.get_env(:ad_butler, :req_options, [])

  defp make_request(method, url, opts) do
    headers = Keyword.get(opts, :headers, [])
    params = Keyword.get(opts, :params, [])
    ad_account_id = Keyword.get(opts, :ad_account_id)
    fetch_all_pages(method, url, headers, params, ad_account_id, [])
  end

  # Follows Meta API pagination cursors until `paging.next` is absent.
  # On page 2+, `params` is empty because `next_url` already contains the cursor.
  defp fetch_all_pages(method, url, headers, params, ad_account_id, acc) do
    case Req.request(
           req_options() ++ [method: method, url: url, headers: headers, params: params]
         ) do
      {:ok, %{status: 200} = resp} ->
        body = decode_body(resp.body)
        parse_rate_limit_header(resp, ad_account_id)

        case body do
          %{"data" => data, "paging" => %{"next" => next_url}} ->
            fetch_all_pages(method, next_url, headers, [], ad_account_id, [data | acc])

          %{"data" => data} ->
            {:ok, [data | acc] |> Enum.reverse() |> List.flatten()}

          other ->
            {:ok, other}
        end

      {:ok, resp} ->
        {:error, handle_error(%{resp | body: decode_body(resp.body)})}

      {:error, %{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp decode_body(body), do: body

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

  @impl true
  @spec get_insights(String.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def get_insights(ad_account_id, access_token, opts \\ []) do
    {since, until_date} = insights_time_range(opts)

    case make_request(:get, "#{@graph_api_base}/#{ad_account_id}/insights",
           params: [
             level: "ad",
             fields:
               "ad_id,date_start,spend,impressions,clicks,reach,frequency,ctr,cpm,cpc,actions,action_values",
             time_range: Jason.encode!(%{since: since, until: until_date}),
             breakdowns: "publisher_platform"
           ],
           headers: auth_header(access_token),
           ad_account_id: ad_account_id
         ) do
      {:ok, rows} when is_list(rows) ->
        {:ok, Enum.map(rows, &parse_insight_row/1)}

      {:ok, other} ->
        {:ok, other}

      {:error, _} = err ->
        err
    end
  end

  defp insights_time_range(opts) do
    case Keyword.get(opts, :time_range) do
      %{since: since, until: until_date} ->
        {to_string(since), to_string(until_date)}

      nil ->
        today = Date.utc_today()
        since = Date.add(today, -2)
        {Date.to_iso8601(since), Date.to_iso8601(today)}
    end
  end

  defp parse_insight_row(row) do
    %{
      "ad_id" => ad_id,
      "date_start" => date_start
    } = row

    %{
      ad_id: ad_id,
      date_start: date_start,
      spend_cents: parse_money_cents(row["spend"]),
      impressions: parse_integer(row["impressions"]),
      clicks: parse_integer(row["clicks"]),
      reach_count: parse_integer(row["reach"]),
      frequency: parse_float(row["frequency"]),
      conversions: extract_conversions(row["actions"]),
      conversion_value_cents: extract_conversion_value_cents(row["action_values"]),
      ctr_numeric: parse_float(row["ctr"]),
      cpm_cents: parse_money_cents(row["cpm"]),
      cpc_cents: parse_money_cents(row["cpc"]),
      cpa_cents: nil,
      by_placement_jsonb: nil,
      by_age_gender_jsonb: nil
    }
  end

  defp extract_conversions(nil), do: 0

  defp extract_conversions(actions) when is_list(actions) do
    actions
    |> Enum.filter(fn a ->
      a["action_type"] in [
        "offsite_conversion.fb_pixel_purchase",
        "purchase"
      ]
    end)
    |> Enum.reduce(0, fn a, acc ->
      acc + round(parse_float_val(a["value"]))
    end)
  end

  defp extract_conversion_value_cents(nil), do: 0

  defp extract_conversion_value_cents(action_values) when is_list(action_values) do
    action_values
    |> Enum.filter(fn a ->
      a["action_type"] in [
        "offsite_conversion.fb_pixel_purchase",
        "purchase"
      ]
    end)
    |> Enum.reduce(0.0, fn a, acc -> acc + parse_float_val(a["value"]) end)
    |> then(&round(&1 * 100))
  end

  defp parse_money_cents(nil), do: nil
  defp parse_money_cents(v) when is_number(v), do: round(v * 100)

  defp parse_money_cents(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> round(f * 100)
      :error -> nil
    end
  end

  defp parse_integer(nil), do: 0
  defp parse_integer(v) when is_integer(v), do: v

  defp parse_integer(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_float(nil), do: nil

  defp parse_float(v) do
    case parse_float_val(v) do
      f when is_float(f) -> Decimal.from_float(f)
      _ -> nil
    end
  end

  defp parse_float_val(v) when is_float(v), do: v
  defp parse_float_val(v) when is_integer(v), do: v * 1.0

  defp parse_float_val(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float_val(nil), do: 0.0

  @doc "Returns the configured Meta API client module (injectable for testing)."
  def client, do: Application.get_env(:ad_butler, :meta_client, __MODULE__)
end
