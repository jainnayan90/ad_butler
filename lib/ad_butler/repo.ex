defmodule AdButler.Repo do
  use Ecto.Repo,
    otp_app: :ad_butler,
    adapter: Ecto.Adapters.Postgres
end
