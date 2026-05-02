defmodule AdButler.Chat.Message do
  @moduledoc """
  Schema for one message in a chat session. `role` distinguishes user input,
  assistant turns, tool-call/tool-result records, and system errors. The
  jsonb `tool_calls` / `tool_results` arrays default to `[]` (not `nil`) so
  callers can `Enum.map/2` without a nil check.

  `request_id` correlates an assistant turn to its `llm_usage` row; the
  ReqLLM telemetry handler writes the same id into both records.

  `status` is `"streaming"` (in-flight assistant turn), `"complete"`, or
  `"error"`. A `Chat.Server` `terminate/2` flips any lingering `streaming`
  rows to `error` so a reconnect doesn't see a half-written turn.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias AdButler.Chat.Session

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @valid_roles ~w(user assistant tool system_error)
  @valid_statuses ~w(streaming complete error)

  schema "chat_messages" do
    field :role, :string
    field :content, :string
    field :tool_calls, {:array, :map}, default: []
    field :tool_results, {:array, :map}, default: []
    field :request_id, :string, redact: true
    field :status, :string, default: "complete"
    field :inserted_at, :utc_datetime_usec

    belongs_to :session, Session, foreign_key: :chat_session_id
  end

  @type t :: %__MODULE__{}

  @doc "Returns the list of valid role strings."
  @spec roles() :: [String.t()]
  def roles, do: @valid_roles

  @doc "Returns the list of valid status strings."
  @spec statuses() :: [String.t()]
  def statuses, do: @valid_statuses

  @required [:chat_session_id, :role]
  @optional [:content, :tool_calls, :tool_results, :request_id, :status, :inserted_at]

  @doc """
  Builds a changeset for creating a chat message. Requires
  `:chat_session_id`, `:role`, and `:content` (the latter only for non-tool
  roles — tool messages may carry only `tool_results`).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_content_required()
    |> validate_inclusion(:role, @valid_roles)
    |> validate_inclusion(:status, @valid_statuses)
    |> assoc_constraint(:session)
  end

  @doc """
  Builds a changeset that updates only `tool_results`. Validates that the
  value is a list — anything else returns a changeset with a
  `"must be a list"` error on `:tool_results`.

  Used by `Chat.unsafe_update_message_tool_results/2`. Future validation
  on the JSONB shape goes here so every write path picks it up.
  """
  @spec tool_results_changeset(t(), term()) :: Ecto.Changeset.t()
  def tool_results_changeset(%__MODULE__{} = message, tool_results) when is_list(tool_results) do
    cast(message, %{tool_results: tool_results}, [:tool_results])
  end

  def tool_results_changeset(%__MODULE__{} = message, _other) do
    message
    |> change(%{})
    |> add_error(:tool_results, "must be a list")
  end

  defp validate_content_required(changeset) do
    role = get_field(changeset, :role)

    if role in ["user", "assistant", "system_error"] do
      validate_required(changeset, [:content])
    else
      changeset
    end
  end
end
