defmodule AdButler.Repo.Migrations.CreatePendingConfirmations do
  use Ecto.Migration

  def change do
    create table(:pending_confirmations, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :chat_message_id,
          references(:chat_messages, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :token, :text, null: false
      add :action, :text, null: false
      add :args, :jsonb, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:pending_confirmations, [:token])
    create index(:pending_confirmations, [:expires_at])

    create unique_index(:pending_confirmations, [:chat_message_id],
             name: :pending_confirmations_chat_message_id_open_index,
             where: "consumed_at IS NULL"
           )
  end
end
