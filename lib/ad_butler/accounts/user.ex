defmodule AdButler.Accounts.User do
  @moduledoc """
  Schema for a registered user, identified by their Meta (Facebook) account.

  Users are uniquely keyed on `meta_user_id`. The `email` field is optional —
  Facebook Login for Business does not expose the email permission.
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

  @doc "Builds a changeset for a user. Requires `meta_user_id`; `email` and `name` are optional."
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :meta_user_id, :name])
    |> validate_required([:meta_user_id])
    |> validate_format(:email, ~r/@/, allow_nil: true)
    |> validate_format(:meta_user_id, ~r/^[1-9]\d{0,19}$/)
    |> unique_constraint(:meta_user_id)
    |> unique_constraint(:email)
  end
end
