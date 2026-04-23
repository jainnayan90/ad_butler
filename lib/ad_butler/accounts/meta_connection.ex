defmodule AdButler.Accounts.MetaConnection do
  @moduledoc """
  Schema for a Meta (Facebook) OAuth connection belonging to a user.

  Stores the encrypted long-lived access token, its expiry, granted scopes, and
  lifecycle status (`active`, `expired`, `revoked`, `error`). The `access_token`
  field is excluded from `Inspect` output to prevent accidental log exposure.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @derive {Inspect, except: [:access_token]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meta_connections" do
    field :meta_user_id, :string
    field :access_token, AdButler.Encrypted.Binary, redact: true
    field :token_expires_at, :utc_datetime_usec
    field :scopes, {:array, :string}
    field :status, :string, default: "active"

    belongs_to :user, AdButler.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds a changeset for a `MetaConnection`. Validates required fields, status inclusion, and the user+meta_user_id uniqueness constraint."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(meta_connection, attrs) do
    meta_connection
    |> cast(attrs, [:user_id, :meta_user_id, :access_token, :token_expires_at, :scopes, :status])
    |> validate_required([:user_id, :meta_user_id, :access_token, :token_expires_at, :scopes])
    |> validate_inclusion(:status, ["active", "expired", "revoked", "error"])
    |> unique_constraint([:user_id, :meta_user_id])
  end
end
