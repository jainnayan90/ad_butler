defmodule AdButler.LLM.Usage do
  @moduledoc """
  Ecto schema for the `llm_usage` table.

  Append-only — rows are inserted via telemetry events and never updated.
  The `metadata` field is stored encrypted using `AdButler.Encrypted.Binary`;
  callers should pass a map which is serialised to JSON before encryption.

  `request_id` is the idempotency key: inserts use `on_conflict: :nothing`
  keyed on `[:request_id]` to prevent double-writes from retried telemetry
  events.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias AdButler.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "llm_usage" do
    field :conversation_id, :binary_id
    field :turn_id, :binary_id
    field :purpose, :string
    field :provider, :string
    field :model, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cached_tokens, :integer
    field :cost_cents_input, :integer
    field :cost_cents_output, :integer
    field :cost_cents_total, :integer
    field :latency_ms, :integer
    field :status, :string
    field :request_id, :string
    field :metadata, AdButler.Encrypted.Binary

    belongs_to :user, User

    timestamps()
  end

  @required [
    :user_id,
    :purpose,
    :provider,
    :model,
    :input_tokens,
    :output_tokens,
    :cached_tokens,
    :cost_cents_input,
    :cost_cents_output,
    :cost_cents_total,
    :status
  ]
  @optional [:conversation_id, :turn_id, :latency_ms, :request_id, :metadata]

  @doc """
  Changeset for inserting a new `llm_usage` row.

  Validates required fields and non-negative token/cost counts.
  """
  def changeset(usage, attrs) do
    usage
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:input_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:output_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cached_tokens, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents_input, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents_output, greater_than_or_equal_to: 0)
    |> validate_number(:cost_cents_total, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, ~w(success error pending timeout partial))
    |> validate_inclusion(:provider, ~w(anthropic openai google))
    |> validate_inclusion(
      :purpose,
      ~w(chat_response embedding finding_summary tool_arg_classification)
    )
  end
end
