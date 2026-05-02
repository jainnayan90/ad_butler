defmodule AdButler.Repo.Migrations.CreateChatMessages do
  use Ecto.Migration

  def change do
    create table(:chat_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :chat_session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role, :text, null: false
      add :content, :text
      add :tool_calls, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :tool_results, :jsonb, null: false, default: fragment("'[]'::jsonb")
      add :request_id, :text
      add :status, :text, null: false, default: "complete"
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:chat_messages, [:chat_session_id, :inserted_at])

    create constraint(:chat_messages, :role_values,
             check: "role IN ('user','assistant','tool','system_error')"
           )

    create constraint(:chat_messages, :status_values,
             check: "status IN ('streaming','complete','error')"
           )
  end
end
