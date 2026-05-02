defmodule AdButler.Repo.Migrations.CreateChatSessions do
  use Ecto.Migration

  def change do
    create table(:chat_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :ad_account_id,
          references(:ad_accounts, type: :binary_id, on_delete: :nilify_all)

      add :title, :text
      add :status, :text, null: false, default: "active"
      add :last_activity_at, :utc_datetime_usec, null: false, default: fragment("now()")

      timestamps(type: :utc_datetime_usec)
    end

    create index(:chat_sessions, [:user_id, :last_activity_at],
             name: :chat_sessions_user_id_last_activity_at_index
           )

    create constraint(:chat_sessions, :status_values, check: "status IN ('active','archived')")
  end
end
