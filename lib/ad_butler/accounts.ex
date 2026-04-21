defmodule AdButler.Accounts do
  import Ecto.Query

  alias AdButler.Accounts.{MetaConnection, User}
  alias AdButler.Meta
  alias AdButler.Repo

  @spec authenticate_via_meta(String.t()) ::
          {:ok, %User{}, %MetaConnection{}} | {:error, term()}
  def authenticate_via_meta(code) do
    with {:ok, %{access_token: token, expires_in: expires_in}} <-
           Meta.Client.exchange_code(code),
         {:ok, user_info} <- Meta.Client.get_me(token) do
      result =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:user, fn _repo, _changes ->
          create_or_update_user(user_info)
        end)
        |> Ecto.Multi.run(:conn_record, fn _repo, %{user: user} ->
          create_meta_connection(user, %{
            meta_user_id: user_info[:meta_user_id],
            access_token: token,
            token_expires_at: DateTime.add(DateTime.utc_now(), expires_in, :second),
            scopes: ["ads_read", "ads_management", "email"]
          })
        end)
        |> Repo.transaction()

      case result do
        {:ok, %{user: user, conn_record: conn_record}} -> {:ok, user, conn_record}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @spec get_user(binary()) :: %User{} | nil
  def get_user(id), do: Repo.get(User, id)

  @spec get_user!(binary()) :: %User{}
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user_by_email(String.t()) :: %User{} | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  @spec create_or_update_user(map()) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def create_or_update_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :email, :updated_at]},
      conflict_target: :meta_user_id,
      returning: true
    )
  end

  @spec get_meta_connection!(binary()) :: %MetaConnection{}
  def get_meta_connection!(id), do: Repo.get!(MetaConnection, id)

  @spec get_meta_connection(binary()) :: %MetaConnection{} | nil
  def get_meta_connection(id), do: Repo.get(MetaConnection, id)

  @spec create_meta_connection(%User{}, map()) ::
          {:ok, %MetaConnection{}} | {:error, Ecto.Changeset.t()}
  def create_meta_connection(user, attrs) do
    %MetaConnection{user_id: user.id}
    |> MetaConnection.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :updated_at]},
      conflict_target: [:user_id, :meta_user_id],
      returning: true
    )
  end

  @spec update_meta_connection(%MetaConnection{}, map()) ::
          {:ok, %MetaConnection{}} | {:error, Ecto.Changeset.t()}
  def update_meta_connection(connection, attrs) do
    connection
    |> MetaConnection.changeset(attrs)
    |> Repo.update()
  end

  @spec list_meta_connections(%User{}) :: [%MetaConnection{}]
  def list_meta_connections(user) do
    MetaConnection
    |> where([mc], mc.user_id == ^user.id and mc.status == "active")
    |> Repo.all()
  end
end
