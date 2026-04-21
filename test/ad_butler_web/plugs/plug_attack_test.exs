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

  defp unique_octet do
    rem(System.unique_integer([:positive]), 250) + 1
  end
end
