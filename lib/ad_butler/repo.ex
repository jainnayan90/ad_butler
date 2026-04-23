defmodule AdButler.Repo do
  @moduledoc """
  Ecto repository for AdButler, backed by PostgreSQL.
  """

  use Ecto.Repo,
    otp_app: :ad_butler,
    adapter: Ecto.Adapters.Postgres
end
