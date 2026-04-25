defmodule AdButler.Accounts.User do
  @moduledoc """
  Schema for a registered user, identified by their Meta (Facebook) account.

  Users are uniquely keyed on `meta_user_id`. The `email` field is populated from
  the Meta `/me` endpoint and kept up to date on every OAuth login.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :meta_user_id, :string
    field :name, :string

    has_many :meta_connections, AdButler.Accounts.MetaConnection

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds a changeset for a user. Requires `email` and `meta_user_id`; validates format and uniqueness."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :meta_user_id, :name])
    |> validate_required([:email, :meta_user_id])
    |> validate_format(:email, ~r/@/)
    |> validate_format(:meta_user_id, ~r/^[1-9]\d{0,19}$/)
    |> unique_constraint(:meta_user_id)
    |> unique_constraint(:email)
  end
end
