defmodule AdButler.Repo.Migrations.AddBmIdAndBmNameToAdAccounts do
  use Ecto.Migration

  def change do
    alter table(:ad_accounts) do
      add :bm_id, :string, null: true
      add :bm_name, :string, null: true
    end

    create index(:ad_accounts, [:bm_id])
  end
end
