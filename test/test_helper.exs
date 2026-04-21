citext_ok =
  case AdButler.Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'citext'") do
    {:ok, %{rows: [[1]]}} -> true
    _ -> false
  end

excludes = if citext_ok, do: [], else: [:requires_citext]
ExUnit.start(exclude: excludes)
Ecto.Adapters.SQL.Sandbox.mode(AdButler.Repo, :manual)
