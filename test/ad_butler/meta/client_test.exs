defmodule AdButler.Meta.ClientTest do
  # async: false — :meta_rate_limits ETS table is process-global
  use ExUnit.Case, async: false

  alias AdButler.Meta.Client

  @rate_limit_table :meta_rate_limits

  setup do
    orig_req_options = Application.get_env(:ad_butler, :req_options)
    orig_app_id = Application.get_env(:ad_butler, :meta_app_id)
    orig_app_secret = Application.get_env(:ad_butler, :meta_app_secret)
    orig_callback_url = Application.get_env(:ad_butler, :meta_oauth_callback_url)

    Application.put_env(:ad_butler, :req_options, plug: {Req.Test, AdButler.Meta.Client})
    Application.put_env(:ad_butler, :meta_app_id, "test_app_id")
    Application.put_env(:ad_butler, :meta_app_secret, "test_app_secret")

    Application.put_env(
      :ad_butler,
      :meta_oauth_callback_url,
      "http://localhost/auth/meta/callback"
    )

    on_exit(fn ->
      restore_or_delete(:req_options, orig_req_options)
      restore_or_delete(:meta_app_id, orig_app_id)
      restore_or_delete(:meta_app_secret, orig_app_secret)
      restore_or_delete(:meta_oauth_callback_url, orig_callback_url)
    end)

    :ok
  end

  defp restore_or_delete(key, nil), do: Application.delete_env(:ad_butler, key)
  defp restore_or_delete(key, val), do: Application.put_env(:ad_butler, key, val)

  describe "list_ad_accounts/1" do
    test "returns ok with data list and writes ETS entry on rate-limit header" do
      on_exit(fn -> :ets.delete(:meta_rate_limits, "act_123") end)

      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn =
          Plug.Conn.put_resp_header(
            conn,
            "x-business-use-case-usage",
            Jason.encode!(%{
              "act_123" => [%{"call_count" => 5, "cpu_time" => 10, "total_time" => 20}]
            })
          )

        Req.Test.json(conn, %{"data" => [%{"id" => "act_123", "name" => "Test Account"}]})
      end)

      assert {:ok, [%{"id" => "act_123"}]} = Client.list_ad_accounts("token_abc")
    end
  end

  describe "get_rate_limit_usage/1" do
    test "returns 0.0 when no ETS entry exists" do
      assert Client.get_rate_limit_usage("act_nonexistent") == 0.0
    end

    test "returns float after ETS is populated" do
      on_exit(fn -> :ets.delete(@rate_limit_table, "act_999") end)
      :ets.insert(@rate_limit_table, {"act_999", {50, 10, 20, DateTime.utc_now()}})
      assert Client.get_rate_limit_usage("act_999") == 0.5
    end
  end

  describe "batch_request/2" do
    test "POSTs requests as JSON and returns decoded list" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, [%{"body" => "{\"data\":[]}"}])
      end)

      requests = [%{"method" => "GET", "relative_url" => "/me"}]
      assert {:ok, [_]} = Client.batch_request("token_abc", requests)
    end
  end

  describe "exchange_code/1" do
    test "happy path: 200 with access_token returns {:ok, %{access_token, expires_in}}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"access_token" => "my_token", "expires_in" => 3600})
      end)

      assert {:ok, %{access_token: "my_token", expires_in: 3600}} =
               Client.exchange_code("code123")
    end

    test "happy path: missing expires_in falls back to default TTL" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"access_token" => "my_token"})
      end)

      assert {:ok, %{access_token: "my_token", expires_in: expires_in}} =
               Client.exchange_code("code123")

      assert expires_in == 60 * 24 * 60 * 60
    end

    test "error path: non-200 returns {:error, {:token_exchange_failed, body}}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid code"}})
      end)

      assert {:error, {:token_exchange_failed, _body}} =
               Client.exchange_code("bad_code")
    end
  end

  describe "get_me/1" do
    test "happy path: returns id, name, email" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"id" => "111111", "name" => "Alice", "email" => "alice@example.com"})
      end)

      assert {:ok, %{name: "Alice", email: "alice@example.com", meta_user_id: "111111"}} =
               Client.get_me("token")
    end

    test "error path: non-200 returns {:error, {:user_info_failed, body}}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"message" => "Invalid token"}})
      end)

      assert {:error, {:user_info_failed, _body}} = Client.get_me("bad_token")
    end

    test "missing email field: returns nil for email" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"id" => "222222", "name" => "Bob"})
      end)

      assert {:ok, %{email: nil}} = Client.get_me("token")
    end
  end

  describe "list_campaigns/3" do
    test "follows paging.next and merges all pages into a single list" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        if conn.query_string =~ "after=cursor1" do
          Req.Test.json(conn, %{"data" => [%{"id" => "camp_2"}]})
        else
          Req.Test.json(conn, %{
            "data" => [%{"id" => "camp_1"}],
            "paging" => %{
              "next" =>
                "https://graph.facebook.com/v23.0/act_123/campaigns?after=cursor1&fields=id"
            }
          })
        end
      end)

      assert {:ok, results} = Client.list_campaigns("act_123", "token")
      assert length(results) == 2
      assert Enum.map(results, & &1["id"]) == ["camp_1", "camp_2"]
    end

    test "200 with data returns {:ok, list}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "camp_1", "name" => "Campaign 1"}]})
      end)

      assert {:ok, [%{"id" => "camp_1"}]} = Client.list_campaigns("act_123", "token")
    end

    test "200 without data key returns {:ok, body}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{})
      end)

      assert {:ok, %{}} = Client.list_campaigns("act_123", "token")
    end

    test "401 returns {:error, :unauthorized}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 401}, %{"error" => %{"message" => "Invalid token"}})
      end)

      assert {:error, :unauthorized} = Client.list_campaigns("act_123", "bad_token")
    end

    test "429 returns {:error, :rate_limit_exceeded}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 429}, %{"error" => %{"message" => "Rate limit"}})
      end)

      assert {:error, :rate_limit_exceeded} = Client.list_campaigns("act_123", "token")
    end

    test "500 returns {:error, :meta_server_error}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 500}, %{"error" => %{"message" => "Server error"}})
      end)

      assert {:error, :meta_server_error} = Client.list_campaigns("act_123", "token")
    end
  end

  describe "list_ad_sets/3" do
    test "200 returns {:ok, list}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "adset_1"}]})
      end)

      assert {:ok, [%{"id" => "adset_1"}]} = Client.list_ad_sets("act_123", "token")
    end

    test "401 returns {:error, :unauthorized}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 401}, %{"error" => %{"message" => "Invalid token"}})
      end)

      assert {:error, :unauthorized} = Client.list_ad_sets("act_123", "bad_token")
    end

    test "429 returns {:error, :rate_limit_exceeded}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 429}, %{"error" => %{"message" => "Rate limit"}})
      end)

      assert {:error, :rate_limit_exceeded} = Client.list_ad_sets("act_123", "token")
    end
  end

  describe "list_ads/3" do
    test "200 returns {:ok, list}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => "ad_1"}]})
      end)

      assert {:ok, [%{"id" => "ad_1"}]} = Client.list_ads("act_123", "token")
    end

    test "401 returns {:error, :unauthorized}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 401}, %{"error" => %{"message" => "Invalid token"}})
      end)

      assert {:error, :unauthorized} = Client.list_ads("act_123", "bad_token")
    end

    test "429 returns {:error, :rate_limit_exceeded}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 429}, %{"error" => %{"message" => "Rate limit"}})
      end)

      assert {:error, :rate_limit_exceeded} = Client.list_ads("act_123", "token")
    end
  end

  describe "refresh_token/1" do
    test "200 success returns {:ok, body}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"access_token" => "new_token", "expires_in" => 5_000_000})
      end)

      assert {:ok, %{"access_token" => "new_token"}} = Client.refresh_token("old_token")
    end

    test "401 revoked returns {:error, :unauthorized}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 401}, %{"error" => %{"message" => "Revoked token"}})
      end)

      assert {:error, :unauthorized} = Client.refresh_token("revoked_token")
    end

    test "server error returns {:error, :meta_server_error}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 503}, %{"error" => %{"message" => "Service unavailable"}})
      end)

      assert {:error, :meta_server_error} = Client.refresh_token("token")
    end
  end

  describe "get_creative/2" do
    test "200 returns {:ok, body}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{"id" => "creative_1", "name" => "My Creative"})
      end)

      assert {:ok, %{"id" => "creative_1"}} = Client.get_creative("creative_1", "token")
    end

    test "404 returns {:error, :unknown_error}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 404}, %{"error" => %{"message" => "Not found"}})
      end)

      assert {:error, :unknown_error} = Client.get_creative("missing_id", "token")
    end

    test "non-200 error returns {:error, term}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 503}, %{"error" => %{"message" => "Service unavailable"}})
      end)

      assert {:error, :meta_server_error} = Client.get_creative("creative_1", "token")
    end
  end

  describe "error handling" do
    test "401 returns {:error, :unauthorized}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(
          %{conn | status: 401},
          %{"error" => %{"message" => "Invalid OAuth access token."}}
        )
      end)

      assert {:error, :unauthorized} = Client.list_ad_accounts("bad_token")
    end

    test "429 returns {:error, :rate_limit_exceeded}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 429}, %{"error" => %{"message" => "Rate limit hit"}})
      end)

      assert {:error, :rate_limit_exceeded} = Client.list_ad_accounts("token")
    end

    test "500 returns {:error, :meta_server_error}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(%{conn | status: 500}, %{"error" => %{"message" => "Server error"}})
      end)

      assert {:error, :meta_server_error} = Client.list_ad_accounts("token")
    end
  end

  describe "get_insights/3" do
    test "happy path: returns parsed rows with conversions extracted" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "ad_id" => "ad_1",
              "date_start" => "2026-04-01",
              "spend" => "10.50",
              "impressions" => "1000",
              "clicks" => "25",
              "reach" => "800",
              "frequency" => "1.25",
              "ctr" => "2.5",
              "cpm" => "10.50",
              "cpc" => "0.42",
              "actions" => [
                %{"action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "3"},
                %{"action_type" => "link_click", "value" => "25"}
              ],
              "action_values" => [
                %{"action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "150.00"}
              ]
            },
            %{
              "ad_id" => "ad_2",
              "date_start" => "2026-04-01",
              "spend" => "5.00",
              "impressions" => "500",
              "clicks" => "10",
              "reach" => "400",
              "frequency" => "1.25",
              "ctr" => "2.0",
              "cpm" => "10.00",
              "cpc" => "0.50",
              "actions" => nil,
              "action_values" => nil
            }
          ]
        })
      end)

      assert {:ok, [row1, row2]} = Client.get_insights("act_123", "token", [])

      assert row1.ad_id == "ad_1"
      assert row1.spend_cents == 1050
      assert row1.impressions == 1000
      assert row1.conversions == 3
      assert row1.conversion_value_cents == 15_000

      assert row2.ad_id == "ad_2"
      assert row2.conversions == 0
    end

    test "400 insufficient permissions returns {:error, {:bad_request, _}}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{
            "message" => "Insufficient permissions",
            "code" => 200
          }
        })
      end)

      assert {:error, {:bad_request, _}} = Client.get_insights("act_123", "token", [])
    end

    test "429 rate limit returns {:error, :rate_limit_exceeded}" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{})
      end)

      assert {:error, :rate_limit_exceeded} = Client.get_insights("act_123", "token", [])
    end
  end

  describe "extract_conversions/1 (via get_insights)" do
    test "sums only purchase action types from mixed actions list" do
      Req.Test.stub(AdButler.Meta.Client, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{
              "ad_id" => "ad_x",
              "date_start" => "2026-04-01",
              "spend" => "0",
              "impressions" => "0",
              "clicks" => "0",
              "reach" => "0",
              "frequency" => "0",
              "ctr" => "0",
              "cpm" => "0",
              "cpc" => "0",
              "actions" => [
                %{"action_type" => "purchase", "value" => "2"},
                %{"action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "5"},
                %{"action_type" => "video_view", "value" => "100"}
              ],
              "action_values" => []
            }
          ]
        })
      end)

      assert {:ok, [row]} = Client.get_insights("act_123", "token", [])
      assert row.conversions == 7
    end
  end
end
