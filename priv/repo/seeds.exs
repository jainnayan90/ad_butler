# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     AdButler.Repo.insert!(%AdButler.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

# --- LLM pricing rows ---
now = DateTime.utc_now() |> DateTime.truncate(:second)

llm_pricing_rows = [
  %{
    provider: "anthropic",
    model: "claude-sonnet-4-6",
    cents_per_1k_input: Decimal.new("0.03"),
    cents_per_1k_output: Decimal.new("0.15"),
    effective_from: ~D[2025-01-01],
    effective_to: nil,
    inserted_at: now
  },
  %{
    provider: "anthropic",
    model: "claude-haiku-4-5-20251001",
    cents_per_1k_input: Decimal.new("0.008"),
    cents_per_1k_output: Decimal.new("0.04"),
    effective_from: ~D[2025-01-01],
    effective_to: nil,
    inserted_at: now
  },
  %{
    provider: "openai",
    model: "text-embedding-3-small",
    cents_per_1k_input: Decimal.new("0.0002"),
    cents_per_1k_output: Decimal.new("0.0"),
    effective_from: ~D[2024-01-01],
    effective_to: nil,
    inserted_at: now
  }
]

Enum.each(llm_pricing_rows, fn row ->
  AdButler.Repo.insert_all("llm_pricing", [row],
    on_conflict: :nothing,
    conflict_target: [:provider, :model, :effective_from]
  )
end)
