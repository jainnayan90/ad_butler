defmodule AdButler.Repo.Migrations.CreateLlmUsage do
  use Ecto.Migration

  def change do
    create table(:llm_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :conversation_id, :uuid
      add :turn_id, :uuid
      add :purpose, :string, null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cached_tokens, :integer, null: false, default: 0
      add :cost_cents_input, :integer, null: false, default: 0
      add :cost_cents_output, :integer, null: false, default: 0
      add :cost_cents_total, :integer, null: false, default: 0
      add :latency_ms, :integer
      add :status, :string, null: false
      add :request_id, :string
      add :metadata, :jsonb, default: "{}"
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:llm_usage, [:user_id, :inserted_at])
    create index(:llm_usage, [:inserted_at], using: :brin)
    create index(:llm_usage, [:conversation_id])

    create constraint(:llm_usage, :non_negative_tokens,
             check: "input_tokens >= 0 AND output_tokens >= 0 AND cached_tokens >= 0"
           )

    create constraint(:llm_usage, :non_negative_costs,
             check: "cost_cents_input >= 0 AND cost_cents_output >= 0 AND cost_cents_total >= 0"
           )

    create constraint(:llm_usage, :status_values,
             check: "status IN ('success','error','pending','timeout','partial')"
           )

    create constraint(:llm_usage, :provider_values,
             check: "provider IN ('anthropic','openai','google')"
           )
  end
end
