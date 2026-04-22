defmodule AdButlerWeb.HealthControllerTest do
  use AdButlerWeb.ConnCase, async: false

  describe "GET /health/liveness" do
    test "returns 200 ok", %{conn: conn} do
      conn = get(conn, ~p"/health/liveness")
      assert response(conn, 200) == "ok"
    end
  end

  describe "GET /health/readiness" do
    test "returns 200 ok when DB is available", %{conn: conn} do
      conn = get(conn, ~p"/health/readiness")
      assert response(conn, 200) == "ok"
    end

    test "returns 503 when DB is unavailable", %{conn: conn} do
      Application.put_env(:ad_butler, :db_ping_fn, fn -> {:error, :timeout} end)
      on_exit(fn -> Application.delete_env(:ad_butler, :db_ping_fn) end)

      conn = get(conn, ~p"/health/readiness")
      assert response(conn, 503) == "unavailable"
    end
  end
end
