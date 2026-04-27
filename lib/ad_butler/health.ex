defmodule AdButler.Health do
  @moduledoc "Internal health checks for the application."

  alias AdButler.Repo
  alias Ecto.Adapters.SQL

  @doc "Pings the database with a 1-second timeout. Returns `{:ok, _}` or `{:error, _}`."
  def db_ping do
    SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)
  end
end
