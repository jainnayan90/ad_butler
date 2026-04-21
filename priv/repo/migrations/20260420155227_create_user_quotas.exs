defmodule AdButler.Repo.Migrations.CreateUserQuotas do
  use Ecto.Migration

  def change do
    create table(:user_quotas, primary_key: false) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        primary_key: true,
        null: false

      add :daily_cost_cents_limit, :bigint, null: false, default: 500
      add :daily_cost_cents_soft, :bigint, null: false, default: 300
      add :monthly_cost_cents_limit, :bigint, null: false, default: 10_000
      add :tier, :string, null: false, default: "free"
      add :cutoff_until, :utc_datetime_usec
      add :note, :text

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:user_quotas, :soft_le_hard,
             check: "daily_cost_cents_soft <= daily_cost_cents_limit"
           )

    create constraint(:user_quotas, :non_negative,
             check:
               "daily_cost_cents_limit >= 0 AND daily_cost_cents_soft >= 0 AND monthly_cost_cents_limit >= 0"
           )

    create constraint(:user_quotas, :tier_values, check: "tier IN ('free','pro','enterprise')")
  end
end
