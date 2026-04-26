defmodule AdButler.Repo.Migrations.MakeUsersEmailOptional do
  use Ecto.Migration

  def up do
    # Facebook Login for Business does not expose the email permission —
    # email is not reliably available and must be optional.
    alter table(:users) do
      modify :email, :string, null: true
    end

    drop_if_exists unique_index(:users, [:email])
  end

  def down do
    create unique_index(:users, [:email])

    alter table(:users) do
      modify :email, :string, null: false
    end
  end
end
