Ecto.Adapters.SQL.Sandbox.mode(AdButler.Repo, :manual)

# Checkout/checkin explicitly so this diagnostic query does not leak a
# connection into the long-lived test runner process (auto mode would keep
# it checked out for the whole suite, reducing the available pool by 1).
citext_ok =
  try do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(AdButler.Repo)

    result =
      case AdButler.Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'citext'") do
        {:ok, %{rows: [[1]]}} -> true
        _ -> false
      end

    Ecto.Adapters.SQL.Sandbox.checkin(AdButler.Repo)
    result
  rescue
    _ -> false
  end

excludes = if citext_ok, do: [], else: [:requires_citext]
ExUnit.start(exclude: excludes)
