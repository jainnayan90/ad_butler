defmodule AdButler.Chat.Session do
  @moduledoc """
  Schema for one chat session — a persistent conversation between a user and
  the agent. Sessions are user-scoped via `user_id`; an optional
  `ad_account_id` pins the session to a specific account when set, otherwise
  the agent operates across all of the user's accounts.

  `last_activity_at` is bumped in the same transaction as every appended
  message (`Chat.append_message/2`), so paginated session listings can sort
  by recency without scanning `chat_messages`.

  `status` is `"active"` or `"archived"` (CHECK enforced at the database).
  Archived sessions are hidden from the default listing but kept for audit
  / replay.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias AdButler.Chat.Message

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_statuses ~w(active archived)

  schema "chat_sessions" do
    field :user_id, :binary_id
    field :ad_account_id, :binary_id
    field :title, :string
    field :status, :string, default: "active"
    field :last_activity_at, :utc_datetime_usec

    has_many :messages, Message, foreign_key: :chat_session_id

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Returns the list of valid status strings."
  @spec statuses() :: [String.t()]
  def statuses, do: @valid_statuses

  @required [:user_id]
  @optional [:ad_account_id, :title, :status, :last_activity_at]

  @doc """
  Builds a changeset for creating or updating a chat session. Requires
  `:user_id`; validates `:status` against the allowed set.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
