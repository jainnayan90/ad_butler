defmodule AdButler.Chat do
  @moduledoc """
  Context for chat sessions, messages, pending confirmations, and the audit
  log of agent-initiated write actions.

  ## Tenant scoping

  Sessions, messages, and pending confirmations are scoped through the
  user FK on `chat_sessions` (or directly on `pending_confirmations`).
  This is the simpler form of `scope/2` — there is no `MetaConnection`
  join in the chain because chat data belongs to a user, not to an ad
  account. Tools that read ad/finding data through this context always
  re-scope through the owning context (`Ads`, `Analytics`), which DO go
  through the `meta_connection_ids` chain.

  This module is the only place outside an Ecto migration that calls
  `Repo` for chat tables. Callers (LiveViews in Week 10, the
  `Chat.Server` runtime in Week 9D2+, tools in Week 9D3+) must use the
  public API here.

  ## Public API surface (Week 9 D1)

  Pagination helpers return `{items, total}` matching `paginate_findings/2`
  in `Analytics`.

    * `list_sessions/2`, `paginate_sessions/2`, `get_session!/2`,
      `get_session/2`, `create_session/1`
    * `list_messages/2`, `paginate_messages/2`, `append_message/1`
    * `record_action_log/1`

  Confirmation helpers (`confirm_tool_call/3`, etc.) land in Week 11.
  """

  import Ecto.Query

  alias AdButler.Chat.{ActionLog, Message, Server, Session}
  alias AdButler.Repo

  @default_per_page 50

  # ---------------------------------------------------------------------------
  # Sessions
  # ---------------------------------------------------------------------------

  @doc """
  Returns the queryable scoped to `user_id`. Composable — pass any
  `Ecto.Queryable` whose root schema is keyed on `user_id` (i.e. the chat
  schemas in this context).
  """
  @spec scope(Ecto.Queryable.t(), binary()) :: Ecto.Query.t()
  def scope(queryable, user_id) when is_binary(user_id) do
    where(queryable, [s], s.user_id == ^user_id)
  end

  @doc """
  Returns all sessions belonging to `user_id`, ordered by most recent
  activity. For paginated UI use `paginate_sessions/2`.
  """
  @spec list_sessions(binary(), keyword()) :: [Session.t()]
  def list_sessions(user_id, opts \\ []) when is_binary(user_id) do
    status = Keyword.get(opts, :status)

    Session
    |> scope(user_id)
    |> apply_session_filters(status: status)
    |> order_by([s], desc: s.last_activity_at)
    |> Repo.all()
  end

  @doc """
  Returns `{items, total}` for the user's sessions. Mirrors
  `Analytics.paginate_findings/2`.

  Options:
    * `:page` — 1-based, default `1`
    * `:per_page` — default `50`
    * `:status` — filter to `"active"` or `"archived"`
  """
  @spec paginate_sessions(binary(), keyword()) :: {[Session.t()], non_neg_integer()}
  def paginate_sessions(user_id, opts \\ []) when is_binary(user_id) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @default_per_page)
    status = Keyword.get(opts, :status)

    base =
      Session
      |> scope(user_id)
      |> apply_session_filters(status: status)

    total = Repo.aggregate(base, :count, :id)

    items =
      base
      |> order_by([s], desc: s.last_activity_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  @doc """
  Returns the session with `id` scoped to `user_id`. Raises
  `Ecto.NoResultsError` on cross-tenant access or a missing row.
  """
  @spec get_session!(binary(), binary()) :: Session.t()
  def get_session!(user_id, id) when is_binary(user_id) and is_binary(id) do
    Session
    |> scope(user_id)
    |> Repo.get!(id)
  end

  @doc """
  Returns `{:ok, session}` for the session with `id` scoped to `user_id`,
  or `{:error, :not_found}` on miss / cross-tenant / invalid UUID.
  """
  @spec get_session(binary(), binary()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(user_id, id) when is_binary(user_id) and is_binary(id) do
    case Session |> scope(user_id) |> Repo.get(id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Returns `{:ok, user_id}` for the session with `id`, or
  `{:error, :not_found}` if no row exists / the id is malformed.

  **Not tenant-scoped — `unsafe_` prefix is a load-bearing warning.**
  Used by `Chat.Server.init/1` to seed `state.user_id` after the caller
  has already authorized the session via `get_session/2`. Public callers
  must use `get_session/2` instead — looking up a user_id without
  authorization would let a caller probe whether arbitrary session_ids
  exist (session enumeration).
  """
  @spec unsafe_get_session_user_id(binary()) :: {:ok, binary()} | {:error, :not_found}
  def unsafe_get_session_user_id(id) when is_binary(id) do
    case Repo.one(from s in Session, where: s.id == ^id, select: s.user_id) do
      nil -> {:error, :not_found}
      user_id -> {:ok, user_id}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Creates a session. Sets `last_activity_at` to `now()` so a freshly-created
  session sorts to the top of `paginate_sessions/2`. Internal callers pass
  atom-keyed maps; the changeset accepts string-keyed maps but the
  `last_activity_at` default is only injected when the map is atom-keyed
  (no clobbering, no clash).
  """
  @spec create_session(map()) :: {:ok, Session.t()} | {:error, Ecto.Changeset.t()}
  def create_session(attrs) when is_map(attrs) do
    attrs = Map.put_new(attrs, :last_activity_at, DateTime.utc_now())

    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  @doc """
  Returns all messages for the given session, ordered ascending by
  `inserted_at`. The session must already have been authorized for the
  caller (use `get_session!/2` upstream).
  """
  @spec list_messages(binary(), keyword()) :: [Message.t()]
  def list_messages(session_id, opts \\ []) when is_binary(session_id) do
    limit = Keyword.get(opts, :limit)

    base =
      from m in Message,
        where: m.chat_session_id == ^session_id,
        order_by: [asc: m.inserted_at]

    base = if limit, do: limit(base, ^limit), else: base

    Repo.all(base)
  end

  @doc """
  Returns `{items, total}` for messages in `session_id`. Items are ordered
  ascending by `inserted_at` (chronological — oldest first), matching how
  the LiveView renders the conversation. Caller is responsible for
  authorising `session_id` against the user.
  """
  @spec paginate_messages(binary(), keyword()) :: {[Message.t()], non_neg_integer()}
  def paginate_messages(session_id, opts \\ []) when is_binary(session_id) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, @default_per_page)

    base = from m in Message, where: m.chat_session_id == ^session_id

    total = Repo.aggregate(base, :count, :id)

    items =
      base
      |> order_by([m], asc: m.inserted_at)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> Repo.all()

    {items, total}
  end

  @doc """
  Returns the message with `id` scoped to `user_id`. Raises
  `Ecto.NoResultsError` on cross-tenant access or a missing row.
  """
  @spec get_message!(binary(), binary()) :: Message.t()
  def get_message!(user_id, id) when is_binary(user_id) and is_binary(id) do
    Message
    |> join(:inner, [m], s in Session, on: s.id == m.chat_session_id)
    |> where([m, s], m.id == ^id and s.user_id == ^user_id)
    |> Repo.one!()
  end

  @doc """
  Returns `{:ok, message}` for the message with `id` scoped to
  `user_id`, or `{:error, :not_found}` on miss / cross-tenant access /
  malformed UUID.

  Joins `chat_sessions` to enforce ownership. Used by `ChatLive.Show`'s
  `:turn_complete` PubSub handler — defence-in-depth in case the
  per-session topic is ever leaked to a foreign subscriber.
  """
  @spec get_message(binary(), binary()) :: {:ok, Message.t()} | {:error, :not_found}
  def get_message(user_id, id) when is_binary(user_id) and is_binary(id) do
    query =
      from m in Message,
        join: s in Session,
        on: s.id == m.chat_session_id,
        where: m.id == ^id and s.user_id == ^user_id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      msg -> {:ok, msg}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  Updates a message's `tool_results` JSONB column.

  **Not tenant-scoped — `unsafe_` prefix is a load-bearing warning.**
  A caller passing an unvalidated `id` would let it write to another
  tenant's message. Public callers must first authorize the parent
  session via `get_session/2`. Currently unused in the streaming path
  (D-W10-03 was reverted; charts render at display time) but retained
  for future cache-style use cases.

  Validates that `tool_results` is a list. Returns
  `{:error, :not_found}` for a missing id and
  `{:error, changeset}` on a non-list input.
  """
  @spec unsafe_update_message_tool_results(binary(), term()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def unsafe_update_message_tool_results(id, tool_results)
      when is_binary(id) and is_list(tool_results) do
    case Repo.get(Message, id) do
      nil ->
        {:error, :not_found}

      message ->
        message
        |> Message.tool_results_changeset(tool_results)
        |> Repo.update()
    end
  end

  def unsafe_update_message_tool_results(id, tool_results) when is_binary(id) do
    {:error, Message.tool_results_changeset(%Message{}, tool_results)}
  end

  @doc """
  Inserts a message and bumps the parent session's `last_activity_at` in
  the same transaction. Returns `{:ok, message}` so callers can pattern
  match on the new row.

  The bump uses the message's `inserted_at` if present (so streaming
  messages whose `inserted_at` was set by the agent appear consistent),
  falling back to `DateTime.utc_now/0`.
  """
  @spec append_message(map()) ::
          {:ok, Message.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :session_not_found}
  def append_message(attrs) when is_map(attrs) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:message, Message.changeset(%Message{}, attrs))
      |> Ecto.Multi.run(:bump_activity, fn repo, %{message: message} ->
        bump_at = message.inserted_at || DateTime.utc_now()

        {count, _} =
          repo.update_all(
            from(s in Session, where: s.id == ^message.chat_session_id),
            set: [last_activity_at: bump_at, updated_at: DateTime.utc_now()]
          )

        if count == 1, do: {:ok, count}, else: {:error, :session_not_found}
      end)

    case Repo.transaction(multi) do
      {:ok, %{message: message}} -> {:ok, message}
      {:error, :message, changeset, _} -> {:error, changeset}
      {:error, :bump_activity, reason, _} -> {:error, reason}
    end
  end

  @doc """
  Flips every `streaming` message in `session_id` to `status: "error"`
  in a single `UPDATE`. Used by `Chat.Server.terminate/2` to clean up
  half-written turns when the server crashes or is shut down mid-stream.

  Idempotent — calling on a clean session no-ops and returns
  `{:ok, 0}`. **Not tenant-scoped — `unsafe_` prefix is a load-bearing
  warning.** A caller passing an unvalidated `session_id` would silently
  corrupt another tenant's in-flight turn (their `streaming` rows flip
  to `error`). The function is keyed on `chat_session_id` only because
  both call sites (Server terminate, internal cleanup tasks) hold an
  already-validated session id.
  """
  @spec unsafe_flip_streaming_messages_to_error(binary()) :: {:ok, non_neg_integer()}
  def unsafe_flip_streaming_messages_to_error(session_id) when is_binary(session_id) do
    {count, _} =
      Repo.update_all(
        from(m in Message,
          where: m.chat_session_id == ^session_id and m.status == "streaming"
        ),
        set: [status: "error"]
      )

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Action log
  # ---------------------------------------------------------------------------

  @doc """
  Inserts a single audit-log row recording a write-tool invocation.

  Read tools must NOT call this — the W9D5 e2e test asserts a read-only
  turn produces zero `actions_log` rows.
  """
  @spec record_action_log(map()) :: {:ok, ActionLog.t()} | {:error, Ecto.Changeset.t()}
  def record_action_log(attrs) when is_map(attrs) do
    %ActionLog{}
    |> ActionLog.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # PubSub
  # ---------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to the chat PubSub topic for
  `session_id`. The `Chat.Server` for the session broadcasts
  `{:chat_chunk, sid, text}`, `{:tool_result, sid, name, status}`,
  `{:turn_complete, sid, msg_id}`, and `{:turn_error, sid, reason}`
  on this topic. Returns `:ok` on success.
  """
  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(AdButler.PubSub, "chat:" <> session_id)
  end

  # ---------------------------------------------------------------------------
  # Process lifecycle (Day 2)
  # ---------------------------------------------------------------------------

  @doc """
  Public entry point for sending a user message into a session.
  Authorises `session_id` against `user_id` via `ensure_server/2`,
  then forwards to the running `Chat.Server`.

  Returns `:ok` once the turn finishes (LLM stream is consumed and the
  assistant message is persisted) or `{:error, reason}` on auth /
  startup / LLM failure. Tools and read errors during the turn are
  reported via PubSub on `"chat:" <> session_id` rather than failing the
  whole call — the agent can recover within a turn.
  """
  @spec send_message(binary(), binary(), String.t()) :: :ok | {:error, term()}
  def send_message(user_id, session_id, body)
      when is_binary(user_id) and is_binary(session_id) and is_binary(body) do
    with {:ok, _pid} <- ensure_server(user_id, session_id) do
      Server.send_user_message(session_id, body)
    end
  end

  @doc """
  Returns `{:ok, pid}` for the running `Chat.Server` for `session_id`,
  starting it under `Chat.SessionSupervisor` if not already running.
  Authorises the session against `user_id` first — cross-tenant or
  missing ids return `{:error, :not_found}`.

  Lazy: the first `send_message/3` call wakes the process; idle
  sessions hibernate after 15 minutes (see `Chat.Server`).

  Authorisation lives at the context boundary so the `Chat.Server`
  itself stays auth-naive. Without this re-validation, a caller that
  knew a session_id could lazy-start a session for any tenant and
  trigger history replay.
  """
  @spec ensure_server(binary(), binary()) :: {:ok, pid()} | {:error, term()}
  def ensure_server(user_id, session_id)
      when is_binary(user_id) and is_binary(session_id) do
    with {:ok, _session} <- get_session(user_id, session_id) do
      start_or_lookup_server(session_id)
    end
  end

  defp start_or_lookup_server(session_id) do
    case Registry.lookup(AdButler.Chat.SessionRegistry, session_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               AdButler.Chat.SessionSupervisor,
               {AdButler.Chat.Server, session_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, _reason} = err -> err
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp apply_session_filters(queryable, opts) do
    Enum.reduce(opts, queryable, fn
      {:status, s}, q when is_binary(s) -> where(q, [s_], s_.status == ^s)
      _, q -> q
    end)
  end
end
