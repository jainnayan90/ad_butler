defmodule AdButler.Repo.Migrations.AddRequestIdUniqueIndexToChatMessages do
  use Ecto.Migration

  def change do
    create unique_index(:chat_messages, [:request_id],
             where: "request_id IS NOT NULL",
             name: :chat_messages_request_id_unique_when_present
           )
  end
end
