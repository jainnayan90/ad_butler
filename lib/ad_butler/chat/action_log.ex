defmodule AdButler.Chat.ActionLog do
  @moduledoc """
  Schema for the audit trail of write-tool invocations the agent has
  attempted on a user's behalf. Read tools never write to this table — the
  W9D5 e2e test asserts a `read_tools` turn produces zero `actions_log`
  rows.

  `outcome` is `"pending"` (queued, awaiting Meta API roundtrip),
  `"success"`, or `"failure"`. `meta_response` captures the raw Meta API
  payload (redacted before storage; see `AdButler.Log.redact/1`).

  Append-only audit log; integer serial PK preserves insert order without
  the per-row UUID overhead. Intentional deviation from the project's
  `binary_id` convention.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias AdButler.Chat.{Message, Session}

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_outcomes ~w(pending success failure)

  schema "actions_log" do
    field :user_id, :binary_id
    field :tool, :string
    field :args, :map
    field :outcome, :string
    field :error_detail, :string
    field :meta_response, :map
    field :inserted_at, :utc_datetime_usec

    belongs_to :session, Session, foreign_key: :chat_session_id
    belongs_to :message, Message, foreign_key: :chat_message_id
  end

  @type t :: %__MODULE__{}

  @doc "Returns the list of valid outcome strings."
  @spec outcomes() :: [String.t()]
  def outcomes, do: @valid_outcomes

  @required [:user_id, :tool, :outcome]
  @optional [:chat_session_id, :chat_message_id, :args, :error_detail, :meta_response]

  @doc "Builds a changeset for inserting an action-log row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(log, attrs) do
    log
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:outcome, @valid_outcomes)
  end
end
