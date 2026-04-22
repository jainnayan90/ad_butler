defmodule AdButlerWeb.PlugAttackTest do
  use AdButlerWeb.ConnCase, async: false

  # PlugAttack ETS table is process-global; async: false prevents cross-test interference.
  # Each test uses a unique IP to avoid bucket collisions across test runs.

  defp conn_with_ip(ip_tuple) do
    build_conn(:get, "/auth/meta/callback")
    |> Map.put(:remote_ip, ip_tuple)
  end

  describe "oauth rate limit" do
    test "first 10 requests from same IP are allowed" do
      {a, b, c, d} = {10, unique_octet(), 0, 1}
      ip = {a, b, c, d}

      results =
        for _i <- 1..10 do
          conn = AdButlerWeb.PlugAttack.call(conn_with_ip(ip), [])
          conn.halted
        end

      assert Enum.all?(results, &(&1 == false))
    end

    test "11th request from same IP is blocked" do
      {a, b, c, d} = {10, unique_octet(), 0, 2}
      ip = {a, b, c, d}

      for _i <- 1..10 do
        AdButlerWeb.PlugAttack.call(conn_with_ip(ip), [])
      end

      conn = AdButlerWeb.PlugAttack.call(conn_with_ip(ip), [])

      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "fly-client-ip header" do
    setup do
      original = Application.get_env(:ad_butler, :trusted_proxy)
      Application.put_env(:ad_butler, :trusted_proxy, :fly)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:ad_butler, :trusted_proxy)
          val -> Application.put_env(:ad_butler, :trusted_proxy, val)
        end
      end)
    end

    test "valid fly-client-ip is used as rate-limit key, not remote_ip" do
      fly_ip = "203.0.113.#{unique_octet()}"

      # All requests appear to come from localhost, but fly-client-ip is the real key
      conn_with_fly =
        conn_with_ip({127, 0, 0, 1})
        |> Plug.Conn.put_req_header("fly-client-ip", fly_ip)

      for _i <- 1..10, do: AdButlerWeb.PlugAttack.call(conn_with_fly, [])

      # 11th with same fly IP is blocked
      assert AdButlerWeb.PlugAttack.call(conn_with_fly, []).halted

      # Same remote_ip but NO fly header → different bucket, not blocked
      conn_no_header = conn_with_ip({127, 0, 0, 1})
      refute AdButlerWeb.PlugAttack.call(conn_no_header, []).halted
    end

    test "spoofed (non-IP) fly-client-ip falls back to remote_ip" do
      {a, b, c, d} = {10, unique_octet(), 1, 1}
      conn = conn_with_ip({a, b, c, d})

      conn_spoofed =
        conn
        |> Plug.Conn.put_req_header("fly-client-ip", "not-an-ip-address")

      for _i <- 1..10, do: AdButlerWeb.PlugAttack.call(conn_spoofed, [])

      # 11th from the same remote_ip is blocked — header was ignored, key = remote_ip
      assert AdButlerWeb.PlugAttack.call(conn, []).halted
    end
  end

  defp unique_octet do
    rem(System.unique_integer([:positive]), 250) + 1
  end
end
