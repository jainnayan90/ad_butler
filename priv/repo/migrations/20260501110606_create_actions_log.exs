defmodule AdButler.Repo.Migrations.CreateActionsLog do
  use Ecto.Migration

  def change do
    # Append-only audit log; integer serial PK preserves insert order without
    # the per-row UUID overhead. Intentional deviation from the project's
    # `binary_id` convention.
    create table(:actions_log) do
      add :user_id, references(:users, type: :binary_id, on_delete: :restrict), null: false

      add :chat_session_id,
          references(:chat_sessions, type: :binary_id, on_delete: :nilify_all)

      add :chat_message_id,
          references(:chat_messages, type: :binary_id, on_delete: :nilify_all)

      add :tool, :text, null: false
      add :args, :jsonb
      add :outcome, :text, null: false
      add :error_detail, :text
      add :meta_response, :jsonb
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:actions_log, [:user_id, :inserted_at])

    create constraint(:actions_log, :outcome_values,
             check: "outcome IN ('pending','success','failure')"
           )
  end
end
