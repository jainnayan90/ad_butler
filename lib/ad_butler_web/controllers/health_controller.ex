defmodule AdButlerWeb.HealthController do
  @moduledoc """
  Controller for Kubernetes / Fly.io health probe endpoints.

  `liveness/2` always returns 200 — it signals the process is alive. `readiness/2`
  checks the database with a 10-second result cache to avoid hammering the DB pool
  during high-frequency probe intervals.
  """

  use AdButlerWeb, :controller

  alias AdButler.Repo
  alias Ecto.Adapters.SQL

  @doc "Returns 200 OK unconditionally — signals the process is alive."
  def liveness(conn, _params) do
    send_resp(conn, 200, "ok")
  end

  @db_check_ttl_seconds 10

  @doc "Returns 200 if the DB is reachable (cached for 10 s), 503 otherwise."
  def readiness(conn, _params) do
    case cached_db_ping() do
      {:ok, _} -> send_resp(conn, 200, "ok")
      {:error, _} -> send_resp(conn, 503, "unavailable")
    end
  end

  defp cached_db_ping do
    now = System.monotonic_time(:second)

    case :persistent_term.get(:health_db_last_ok, nil) do
      ts when is_integer(ts) and now - ts < @db_check_ttl_seconds ->
        {:ok, :cached}

      _ ->
        result = db_ping()
        if match?({:ok, _}, result), do: :persistent_term.put(:health_db_last_ok, now)
        result
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
