defmodule AdButler.Accounts do
  @moduledoc """
  Context for managing users and their Meta (Facebook) OAuth connections.

  Handles user creation/lookup, Meta token exchange, and `MetaConnection` lifecycle
  (create, update, expiry queries). All queries that touch ad data are scoped through
  `MetaConnection` IDs owned by the requesting user.
  """
  import Ecto.Query
  require Logger

  alias AdButler.Accounts.{MetaConnection, User}
  alias AdButler.Meta.Client
  alias AdButler.Repo

  @doc """
  Exchanges a Meta OAuth `code` for a long-lived token, upserts the user, and
  creates or updates their `MetaConnection`. Returns `{:ok, user, connection}` on
  success or `{:error, reason}` if the token exchange or any DB step fails.
  """
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
            scopes: ["ads_read", "ads_management"],
            status: "active"
          })
        end)
        |> Repo.transaction()

      case result do
        {:ok, %{user: user, conn_record: conn_record}} -> {:ok, user, conn_record}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  @doc "Returns the user with the given `id`, or `nil` if not found."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id), do: Repo.get(User, id)

  @doc "Returns the user with the given `id`. Raises if not found."
  @spec get_user!(binary()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Returns the user with the given `email`, or `nil` if not found."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: email)

  @doc """
  Inserts or updates a user keyed on `meta_user_id`. Updates `name`, `email`, and
  `updated_at` on conflict so repeated OAuth logins keep the record fresh.
  """
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

  @doc "Returns the `MetaConnection` with the given `id`. Raises if not found."
  @spec get_meta_connection!(binary()) :: MetaConnection.t()
  def get_meta_connection!(id), do: Repo.get!(MetaConnection, id)

  @doc "Returns all `MetaConnection` records whose IDs are in `ids` as a map keyed by id."
  @spec get_meta_connections_by_ids([binary()]) :: %{binary() => MetaConnection.t()}
  def get_meta_connections_by_ids(ids) when is_list(ids) do
    MetaConnection
    |> where([mc], mc.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  @doc "Returns the `MetaConnection` with the given `id`, or `nil` if not found."
  @spec get_meta_connection(binary()) :: MetaConnection.t() | nil
  def get_meta_connection(id), do: Repo.get(MetaConnection, id)

  @doc """
  Inserts or updates a `MetaConnection` for `user`, keyed on `(user_id, meta_user_id)`.
  Updates `access_token`, `token_expires_at`, `scopes`, and `updated_at` on conflict.
  """
  @spec create_meta_connection(User.t(), map()) ::
          {:ok, MetaConnection.t()} | {:error, Ecto.Changeset.t()}
  def create_meta_connection(user, attrs) do
    %MetaConnection{user_id: user.id}
    |> MetaConnection.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:access_token, :token_expires_at, :scopes, :status, :updated_at]},
      conflict_target: [:user_id, :meta_user_id],
      returning: true
    )
  end

  @doc "Updates an existing `MetaConnection` with `attrs`."
  @spec update_meta_connection(MetaConnection.t(), map()) ::
          {:ok, MetaConnection.t()} | {:error, Ecto.Changeset.t()}
  def update_meta_connection(connection, attrs) do
    connection
    |> MetaConnection.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns all active `MetaConnection` records up to `limit` (default 1000).
  Logs an error and truncates if the cap is hit.

  **Not for production sweep use** — capped at 1000 rows. Use
  `stream_active_meta_connections/1` for sweeps over large datasets.
  """
  # Safety cap — use stream_active_meta_connections/1 for production sweeps.
  @spec list_all_active_meta_connections(pos_integer()) :: [MetaConnection.t()]
  def list_all_active_meta_connections(limit \\ 1000) do
    rows =
      MetaConnection
      |> where([mc], mc.status == "active")
      |> limit(^(limit + 1))
      |> Repo.all()

    if length(rows) > limit do
      Logger.error("list_all_active_meta_connections hit row limit — results truncated",
        limit: limit
      )

      Enum.take(rows, limit)
    else
      rows
    end
  end

  @doc """
  Streams all active `MetaConnection` records in pages of `chunk_size` (default 500).
  Must be called inside a transaction. Use this for production sweeps over large datasets
  instead of `list_all_active_meta_connections/1`.

  ## Example

      Repo.transaction(fn ->
        stream_active_meta_connections()
        |> Stream.chunk_every(200)
        |> Enum.each(&enqueue_jobs/1)
      end)
  """
  @spec stream_active_meta_connections(pos_integer()) :: Enum.t()
  def stream_active_meta_connections(chunk_size \\ 500) do
    MetaConnection
    |> where([mc], mc.status == "active")
    |> Repo.stream(max_rows: chunk_size)
  end

  @doc "Returns the IDs of all active `MetaConnection` records belonging to `user`."
  @spec list_meta_connection_ids_for_user(User.t()) :: [binary()]
  def list_meta_connection_ids_for_user(%User{id: user_id}) do
    MetaConnection
    |> where([mc], mc.user_id == ^user_id and mc.status == "active")
    |> select([mc], mc.id)
    |> Repo.all()
  end

  @doc "Returns all active `MetaConnection` records belonging to `user`."
  @spec list_meta_connections(User.t()) :: [MetaConnection.t()]
  def list_meta_connections(user) do
    MetaConnection
    |> where([mc], mc.user_id == ^user.id and mc.status == "active")
    |> Repo.all()
  end

  @doc """
  Returns a page of MetaConnections for `user` (all statuses) and the total count.
  Options: `:page` (default 1), `:per_page` (default 50).
  """
  @spec paginate_meta_connections(User.t(), keyword()) ::
          {[MetaConnection.t()], non_neg_integer()}
  def paginate_meta_connections(%User{id: user_id}, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)

    base =
      from(mc in MetaConnection, where: mc.user_id == ^user_id, order_by: [desc: mc.inserted_at])

    total = Repo.aggregate(base, :count)
    items = base |> limit(^per_page) |> offset(^((page - 1) * per_page)) |> Repo.all()
    {items, total}
  end

  @doc "Returns all `MetaConnection` records belonging to `user` regardless of status, ordered newest first."
  @spec list_all_meta_connections_for_user(User.t()) :: [MetaConnection.t()]
  def list_all_meta_connections_for_user(%User{id: user_id}) do
    MetaConnection
    |> where([mc], mc.user_id == ^user_id)
    |> order_by([mc], desc: mc.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns active connections whose tokens expire within `days_ahead` days,
  ordered by soonest expiry, up to `limit` rows. Used by
  `TokenRefreshSweepWorker` to find connections that need proactive refreshing.
  """
  @spec list_expiring_meta_connections(pos_integer(), pos_integer()) :: [MetaConnection.t()]
  def list_expiring_meta_connections(days_ahead \\ 14, limit \\ 500) do
    threshold = DateTime.add(DateTime.utc_now(), days_ahead * 86_400, :second)

    MetaConnection
    |> where([mc], mc.status == "active" and mc.token_expires_at < ^threshold)
    |> order_by([mc], asc: mc.token_expires_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Runs `fun` inside a transaction with a stream of active MetaConnections."
  @spec stream_connections_and_run((Enumerable.t() -> any()), keyword()) ::
          {:ok, any()} | {:error, term()}
  def stream_connections_and_run(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(2))
    Repo.transaction(fn -> fun.(stream_active_meta_connections()) end, timeout: timeout)
  end

  defp meta_client, do: Client.client()
end
