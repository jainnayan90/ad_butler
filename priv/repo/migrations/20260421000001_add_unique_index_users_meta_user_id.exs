defmodule AdButler.Repo.Migrations.AddUniqueIndexUsersMetaUserId do
  use Ecto.Migration

  def change do
    drop_if_exists index(:users, [:meta_user_id], name: :users_meta_user_id_index)
    create unique_index(:users, [:meta_user_id])
  end
end
