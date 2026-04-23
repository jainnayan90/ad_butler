Ecto.Adapters.SQL.Sandbox.mode(AdButler.Repo, :manual)

# Checkout/checkin explicitly so this diagnostic query does not leak a
# connection into the long-lived test runner process (auto mode would keep
# it checked out for the whole suite, reducing the available pool by 1).
# DB connection failures are not caught — they raise so CI fails loudly
# rather than silently skipping :requires_citext tests on an unhealthy DB.
:ok = Ecto.Adapters.SQL.Sandbox.checkout(AdButler.Repo)

citext_ok =
  try do
    case AdButler.Repo.query("SELECT 1 FROM pg_extension WHERE extname = 'citext'") do
      {:ok, %{rows: [[1]]}} -> true
      {:ok, _} -> false
      {:error, reason} -> raise "citext probe failed — DB may be unhealthy: #{inspect(reason)}"
    end
  after
    Ecto.Adapters.SQL.Sandbox.checkin(AdButler.Repo)
  end

excludes = if citext_ok, do: [:integration], else: [:requires_citext, :integration]
ExUnit.start(exclude: excludes)
