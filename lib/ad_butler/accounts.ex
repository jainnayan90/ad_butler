defmodule AdButler.Accounts do
  @moduledoc false
  import Ecto.Query
  require Logger

  alias AdButler.Accounts.{MetaConnection, User}
  alias AdButler.Meta.Client
  alias AdButler.Repo

  @spec authenticate_via_meta(String.t()) ::
          {:ok, User.t(), MetaConnection.t()} | {:error, term()}
  def authenticate_via_meta(code) do
    with {:ok, %{access_token: token, expires_in: expires_in}} <-
           meta_client().exchange_code(code),
         {:ok, user_info} <- meta_client().get_me(token) do
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

  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @spec get_user!(binary()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  @spec create_or_update_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_or_update_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:name, :email, :updated_at]},
      conflict_target: :meta_user_id,
      returning: true
    )
  end

  @spec get_meta_connection!(binary()) :: MetaConnection.t()
  def get_meta_connection!(id), do: Repo.get!(MetaConnection, id)

  @spec get_meta_connection(binary()) :: MetaConnection.t() | nil
  def get_meta_connection(id), do: Repo.get(MetaConnection, id)

  @spec create_meta_connection(User.t(), map()) ::
          {:ok, MetaConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_meta_connection(user, attrs) do
    %MetaConnection{user_id: user.id}
    |> MetaConnection.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :updated_at]},
      conflict_target: [:user_id, :meta_user_id],
      returning: true
    )
  end

  @spec update_meta_connection(MetaConnection.t(), map()) ::
          {:ok, MetaConnection.t()} | {:error, Ecto.Changeset.t()}
  def update_meta_connection(connection, attrs) do
    connection
    |> MetaConnection.changeset(attrs)
    |> Repo.update()
  end

  # Safety cap — for >1000 connections, replace with cursor-based batching.
  @spec list_all_active_meta_connections(pos_integer()) :: [MetaConnection.t()]
  def list_all_active_meta_connections(limit \\ 1000) do
    result =
      MetaConnection
      |> where([mc], mc.status == "active")
      |> limit(^limit)
      |> Repo.all()

    result_count = length(result)

    if result_count >= limit do
      Logger.error("list_all_active_meta_connections hit row limit — results truncated",
        count: result_count,
        limit: limit
      )
    end

    result
  end

  @spec list_meta_connection_ids_for_user(User.t()) :: [binary()]
  def list_meta_connection_ids_for_user(%User{id: user_id}) do
    MetaConnection
    |> where([mc], mc.user_id == ^user_id and mc.status == "active")
    |> select([mc], mc.id)
    |> Repo.all()
  end

  @spec list_meta_connections(User.t()) :: [MetaConnection.t()]
  def list_meta_connections(user) do
    MetaConnection
    |> where([mc], mc.user_id == ^user.id and mc.status == "active")
    |> Repo.all()
  end

  @spec list_expiring_meta_connections(pos_integer(), pos_integer()) :: [MetaConnection.t()]
  def list_expiring_meta_connections(days_ahead \\ 70, limit \\ 500) do
    threshold = DateTime.add(DateTime.utc_now(), days_ahead * 86_400, :second)

    MetaConnection
    |> where([mc], mc.status == "active" and mc.token_expires_at < ^threshold)
    |> order_by([mc], asc: mc.token_expires_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp meta_client, do: Client.client()
end
