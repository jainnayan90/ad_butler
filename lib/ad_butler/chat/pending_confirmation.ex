defmodule AdButler.Chat.PendingConfirmation do
  @moduledoc """
  Schema for a write-tool call that is parked awaiting user approval. Created
  when the agent emits a confirmation-required tool result; consumed by the
  user clicking "approve" in the LiveView (Week 11). The `token` is opaque
  and uniquely identifies the pending action across the user's sessions.

  A partial unique index (`pending_confirmations_chat_message_id_open_index`)
  enforces at most one open confirmation per `chat_message_id`. The sweeper
  job (Week 11) deletes rows whose `expires_at` has passed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias AdButler.Chat.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "pending_confirmations" do
    field :user_id, :binary_id
    field :token, :string
    field :action, :string
    field :args, :map
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :inserted_at, :utc_datetime_usec

    belongs_to :message, Message, foreign_key: :chat_message_id
  end

  @type t :: %__MODULE__{}

  @required [:chat_message_id, :user_id, :token, :action, :args, :expires_at]
  @optional [:consumed_at]

  @doc "Builds a changeset for creating a pending confirmation."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(confirmation, attrs) do
    confirmation
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:token)
    |> unique_constraint(:chat_message_id,
      name: :pending_confirmations_chat_message_id_open_index,
      message: "already has an open confirmation"
    )
    |> assoc_constraint(:message)
  end
end
