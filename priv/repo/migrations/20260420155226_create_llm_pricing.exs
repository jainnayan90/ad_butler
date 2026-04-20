defmodule AdButler.Repo.Migrations.CreateLlmPricing do
  use Ecto.Migration

  def change do
    create table(:llm_pricing, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :provider, :string, null: false
      add :model, :string, null: false
      add :cents_per_1k_input, :decimal, precision: 10, scale: 6, null: false
      add :cents_per_1k_output, :decimal, precision: 10, scale: 6, null: false
      add :cents_per_1k_cached_input, :decimal, precision: 10, scale: 6
      add :effective_from, :utc_datetime_usec, null: false
      add :effective_to, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_pricing, [:provider, :model, :effective_from])
    create index(:llm_pricing, [:effective_from])
    create index(:llm_pricing, [:effective_to])

    create constraint(:llm_pricing, :non_negative_prices,
             check:
               "cents_per_1k_input >= 0 AND cents_per_1k_output >= 0 AND (cents_per_1k_cached_input IS NULL OR cents_per_1k_cached_input >= 0)"
           )

    create constraint(:llm_pricing, :effective_range,
             check: "effective_to IS NULL OR effective_to > effective_from"
           )
  end
end
