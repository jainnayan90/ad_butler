defmodule AdButlerWeb.HealthController do
  use AdButlerWeb, :controller

  alias AdButler.Repo
  alias Ecto.Adapters.SQL

  def liveness(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  def readiness(conn, _params) do
    case db_ping() do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 503, "unavailable")
    end
  end

  defp db_ping do
    ping_fn = Application.get_env(:ad_butler, :db_ping_fn, &default_db_ping/0)
    ping_fn.()
  end

  defp default_db_ping do
    SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)
  end
end
