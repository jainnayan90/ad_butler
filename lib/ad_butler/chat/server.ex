defmodule AdButler.Chat.Server do
  @moduledoc """
  Per-session chat agent process. One `Chat.Server` per
  `chat_sessions.id`, lazy-started by `Chat.ensure_server/2` under
  `Chat.SessionSupervisor` and registered as
  `{:via, Registry, {AdButler.Chat.SessionRegistry, session_id}}`.

  End users go through `Chat.ensure_server/2` — `start_link/1` is
  private to the supervisor and bypasses the per-tenant authorisation
  check that `ensure_server/2` performs.

  ## Lifecycle

    * `init/1` loads the last 20 messages via `Chat.list_messages/2` and
      seeds the agent's history. No LLM call here — that's reserved for
      `send_user_message/2`.
    * Idle sessions hibernate after 15 minutes (`hibernate_after: ...`).
      `Chat.Server` holds little state on its own (most lives in the
      Jido AgentServer it links), so hibernation is cheap.
    * `terminate/2` flips any in-flight `streaming` message rows to
      `error` so a reconnect doesn't render a half-written turn.

  ## Per-turn ReAct loop cap (D0010)

  The 6-tool-call cap is enforced here, not on the LLM. Each
  `:tool_call` chunk in the stream bumps `step_count`; on the 7th the
  Server cancels the stream, broadcasts `{:turn_error,
  :loop_cap_exceeded}` over PubSub, and persists the assistant message
  with `status: "error"`. Telemetry: `[:chat, :loop, :cap_hit]`.

  Real tool execution (Day 3+) lives in dispatched `Jido.Action` modules
  routed by the agent. Day 2 wires the plumbing only — `send_user_message/2`
  walks the stream, persists messages, and broadcasts deltas. W9D5
  replaces the placeholder ReAct logic with the full loop.
  """

  use GenServer

  require Logger

  alias AdButler.Chat
  alias AdButler.Chat.{LogRedactor, Message, SystemPrompt, Telemetry, Tools}

  @default_hibernate_after :timer.minutes(15)
  @history_window 20
  @max_tool_calls_per_turn 6

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc false
  @spec start_link(binary()) :: GenServer.on_start()
  def start_link(session_id) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, session_id,
      name: via(session_id),
      hibernate_after: hibernate_after_ms()
    )
  end

  defp hibernate_after_ms do
    Application.get_env(:ad_butler, :chat_server_hibernate_after_ms, @default_hibernate_after)
  end

  @doc "Returns the `:via` tuple used for `Registry` lookup."
  @spec via(binary()) :: {:via, Registry, {module(), binary()}}
  def via(session_id), do: {:via, Registry, {AdButler.Chat.SessionRegistry, session_id}}

  @doc """
  Sends a user message into the session. Persists the user message,
  streams the assistant response from the configured LLM client, and
  returns `:ok` once the turn finishes (or aborts on the loop cap).

  Stream chunks are broadcast over `Phoenix.PubSub` on topic
  `"chat:" <> session_id` as `{:chat_chunk, session_id, text}` (content)
  and terminal events as `{:turn_complete, session_id, message_id}` /
  `{:turn_error, session_id, reason}`.

  This is a blocking call — Week 10 LiveView will spawn a Task to call
  this without blocking the WebSocket process.
  """
  @spec send_user_message(binary(), String.t()) :: :ok | {:error, term()}
  def send_user_message(session_id, body) when is_binary(session_id) and is_binary(body) do
    GenServer.call(via(session_id), {:send_user_message, body}, :infinity)
  end

  @doc """
  Stub for Week 11 — confirms a parked write tool call by token. Returns
  `{:error, :not_implemented}` until W11 lands the
  `pending_confirmations` consumer.
  """
  @spec confirm_tool_call(binary(), String.t(), :approve | :reject) ::
          {:error, :not_implemented}
  def confirm_tool_call(_session_id, _token, _decision) do
    {:error, :not_implemented}
  end

  @doc "Returns the server's current status — `:idle`, `:streaming`, or `:terminated`."
  @spec current_status(binary()) :: :idle | :streaming | :terminated
  def current_status(session_id) do
    GenServer.call(via(session_id), :current_status)
  catch
    :exit, _ -> :terminated
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(session_id) do
    Process.flag(:trap_exit, true)

    case Chat.unsafe_get_session_user_id(session_id) do
      {:ok, user_id} ->
        history =
          session_id
          |> load_recent_messages()
          |> Enum.map(&message_to_map/1)

        state = %{
          session_id: session_id,
          user_id: user_id,
          history: history,
          status: :idle,
          step_count: 0
        }

        {:ok, state}

      {:error, :not_found} ->
        Logger.warning("chat: server start aborted, session not found",
          session_id: session_id
        )

        {:stop, :session_not_found}
    end
  end

  @impl GenServer
  def handle_call(:current_status, _from, state) do
    {:reply, state.status, state}
  end

  def handle_call({:send_user_message, body}, _from, state) do
    case persist_user_message(state.session_id, body) do
      {:ok, _user_msg} ->
        state = %{state | status: :streaming, step_count: 0}
        result = run_turn(state, body)
        {:reply, :ok, %{state | status: :idle, step_count: result.step_count}}

      {:error, reason} = err ->
        # Redact: changeset.changes carries the raw user body — never log it.
        Logger.error("chat: failed to persist user message",
          session_id: state.session_id,
          reason: LogRedactor.redact(reason)
        )

        {:reply, err, state}
    end
  end

  @impl GenServer
  def terminate(_reason, %{session_id: session_id}) do
    # Single-statement bulk update; resolves the prior N+1 over an
    # Enum.each/Repo.update loop and keeps Repo out of the runtime layer.
    # Best-effort: if the connection pool is unavailable during shutdown
    # we don't want to crash terminate — the streaming rows will look
    # broken on next mount, which the LiveView already tolerates.
    _ = Chat.unsafe_flip_streaming_messages_to_error(session_id)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ---------------------------------------------------------------------------
  # Turn execution — basic ReAct loop
  # ---------------------------------------------------------------------------

  defp run_turn(state, body) do
    messages = build_request_messages(state, body)

    react_loop(state, messages, %{
      step_count: 0,
      depth: 0,
      user_id: state.user_id,
      turn_id: Ecto.UUID.generate()
    })
  end

  defp react_loop(state, _messages, %{step_count: count})
       when count > @max_tool_calls_per_turn do
    emit_cap_hit(state.session_id, count)
    persist_cap_error(state.session_id)
    %{step_count: count}
  end

  defp react_loop(state, messages, ctx) do
    request_id = Ecto.UUID.generate()

    Telemetry.set_context(%{
      user_id: state.user_id,
      conversation_id: state.session_id,
      turn_id: ctx.turn_id,
      purpose: "chat_response",
      request_id: request_id
    })

    try do
      handle_stream_result(
        llm_client().stream(messages, tools: Tools.read_tools()),
        state,
        messages,
        ctx,
        request_id
      )
    after
      Telemetry.clear_context()
    end
  end

  defp handle_stream_result({:ok, handle}, state, messages, ctx, request_id) do
    chunks = handle |> stream_from_handle() |> Enum.to_list()
    content = collect_content(chunks, state.session_id)
    tool_calls = collect_tool_calls(chunks)

    react_step(tool_calls, content, handle, state, messages, ctx, request_id)
  end

  defp handle_stream_result({:error, reason}, state, _messages, ctx, _request_id) do
    Logger.error("chat: LLM stream failed",
      session_id: state.session_id,
      reason: LogRedactor.redact(reason)
    )

    broadcast(state.session_id, {:turn_error, state.session_id, reason})
    %{step_count: ctx.step_count}
  end

  # No tool calls — final assistant turn, persist and exit.
  defp react_step([], content, _handle, state, _messages, ctx, request_id) do
    persist_assistant(state.session_id, content, request_id)
    %{step_count: ctx.step_count}
  end

  # Tool calls present — recurse if cap allows, else abort.
  defp react_step(tool_calls, content, handle, state, messages, ctx, _request_id) do
    new_count = ctx.step_count + length(tool_calls)

    if new_count > @max_tool_calls_per_turn do
      cancel_handle(handle)
      emit_cap_hit(state.session_id, new_count)
      persist_cap_error(state.session_id)
      %{step_count: new_count}
    else
      tool_results = run_tools(tool_calls, ctx.user_id, state.session_id)
      persist_tool_turn(state.session_id, ctx.turn_id, tool_calls, tool_results)

      new_messages =
        messages ++
          [
            %{role: "assistant", content: content, tool_calls: tool_calls},
            %{role: "tool", content: format_tool_results(tool_results, state.session_id)}
          ]

      react_loop(state, new_messages, %{
        ctx
        | step_count: new_count,
          depth: ctx.depth + 1
      })
    end
  end

  defp collect_content(chunks, session_id) do
    chunks
    |> Enum.filter(&(&1.type == :content and is_binary(&1.text)))
    |> Enum.map_join("", fn chunk ->
      if chunk.text != "", do: broadcast(session_id, {:chat_chunk, session_id, chunk.text})
      chunk.text
    end)
  end

  defp collect_tool_calls(chunks) do
    Enum.filter(chunks, &(&1.type == :tool_call))
  end

  defp run_tools(tool_calls, user_id, session_id) do
    context = %{session_context: %{user_id: user_id}}
    Enum.map(tool_calls, &dispatch_tool(&1, context, session_id))
  end

  defp dispatch_tool(call, context, session_id) do
    case find_tool_module(call.name) do
      nil -> %{name: call.name, error: :unknown_tool}
      mod -> invoke_tool(mod, call, context, session_id)
    end
  end

  defp invoke_tool(mod, call, context, session_id) do
    params = normalise_params(call.arguments || %{})

    case mod.run(params, context) do
      {:ok, result} ->
        broadcast(session_id, {:tool_result, session_id, call.name, :ok})
        %{name: call.name, ok: true, result: result}

      {:error, reason} ->
        broadcast(session_id, {:tool_result, session_id, call.name, :error})
        %{name: call.name, ok: false, error: reason}
    end
  end

  defp find_tool_module(name) when is_binary(name) do
    Enum.find(Tools.all_tools(), fn mod ->
      function_exported?(mod, :name, 0) and mod.name() == name
    end)
  end

  defp find_tool_module(_), do: nil

  defp normalise_params(args) when is_map(args) do
    {kept, unknown} =
      Enum.reduce(args, {%{}, []}, fn
        {k, v}, {acc, unknown} when is_atom(k) ->
          {Map.put(acc, k, v), unknown}

        {k, v}, {acc, unknown} when is_binary(k) ->
          try do
            {Map.put(acc, String.to_existing_atom(k), v), unknown}
          rescue
            ArgumentError -> {acc, [k | unknown]}
          end
      end)

    if unknown != [] do
      Logger.warning("chat: LLM emitted unknown tool param key", unknown_keys: unknown)
    end

    kept
  end

  defp persist_tool_turn(session_id, turn_id, tool_calls, tool_results) do
    Chat.append_message(%{
      chat_session_id: session_id,
      role: "tool",
      tool_calls: Enum.map(tool_calls, &serialise_tool_call(&1, session_id, turn_id)),
      tool_results: tool_results,
      status: "complete"
    })
  end

  defp serialise_tool_call(%{name: name, arguments: args}, _session_id, _turn_id),
    do: %{"name" => name, "arguments" => args}

  defp serialise_tool_call(other, session_id, turn_id) do
    Logger.warning("chat: unrecognised tool_call shape",
      session_id: session_id,
      turn_id: turn_id,
      kind: kind_of(other)
    )

    %{"error" => "unrecognised_tool_call_shape"}
  end

  # `is_struct/1` MUST precede `is_map/1` — every struct is also a map,
  # so reversing these clauses would shadow the struct case and classify
  # every malformed tool call as `"map"` instead of the module name.
  defp kind_of(term) when is_struct(term), do: term.__struct__ |> Atom.to_string()
  defp kind_of(term) when is_map(term), do: "map"
  defp kind_of(term) when is_atom(term), do: Atom.to_string(term)
  defp kind_of(_), do: "other"

  # Public only for unit testing — do not call from outside `Chat.Server`.
  # Returns a JSON string truncated to 4 KB, or a fallback error JSON if
  # `results` cannot be encoded (e.g. a tool smuggled a pid/ref into its
  # result map). Never raises — a non-encodable tool result must not
  # crash the turn.
  @doc false
  @spec format_tool_results(term(), binary() | nil) :: String.t()
  def format_tool_results(results, session_id) do
    case Jason.encode(results) do
      {:ok, json} ->
        String.slice(json, 0, 4_000)

      {:error, reason} ->
        Logger.warning("chat: tool result not encodable",
          session_id: session_id,
          reason: reason
        )

        ~s({"error":"unencodable_tool_result"})
    end
  end

  defp persist_assistant(session_id, content, request_id) do
    case Chat.append_message(%{
           chat_session_id: session_id,
           role: "assistant",
           content: content,
           status: "complete",
           request_id: request_id
         }) do
      {:ok, msg} ->
        broadcast(session_id, {:turn_complete, session_id, msg.id})
        :ok

      {:error, reason} ->
        # Redact: changeset.changes carries the model's content output, which
        # may echo prompt fragments verbatim.
        Logger.error("chat: failed to persist assistant turn",
          session_id: session_id,
          reason: LogRedactor.redact(reason)
        )

        broadcast(session_id, {:turn_error, session_id, :persist_failed})
        :ok
    end
  end

  defp persist_cap_error(session_id) do
    Chat.append_message(%{
      chat_session_id: session_id,
      role: "system_error",
      content: "loop_cap_exceeded",
      status: "error"
    })

    broadcast(session_id, {:turn_complete, session_id, :error})
    :ok
  end

  defp emit_cap_hit(session_id, count) do
    :telemetry.execute(
      [:chat, :loop, :cap_hit],
      %{tool_call_count: count},
      %{session_id: session_id}
    )

    Logger.warning("chat: per-turn tool-call cap hit",
      session_id: session_id,
      count: count
    )

    broadcast(session_id, {:turn_error, session_id, :loop_cap_exceeded})
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp persist_user_message(session_id, body) do
    Chat.append_message(%{
      chat_session_id: session_id,
      role: "user",
      content: body,
      status: "complete"
    })
  end

  defp build_request_messages(state, body) do
    system = %{
      role: "system",
      content:
        SystemPrompt.build(%{
          today: Date.utc_today(),
          user_id: state.user_id,
          ad_account_id: nil
        })
    }

    history_messages =
      Enum.map(state.history, fn msg ->
        %{role: msg.role, content: msg.content || ""}
      end)

    [system | history_messages] ++ [%{role: "user", content: body}]
  end

  defp load_recent_messages(session_id) do
    session_id
    |> Chat.list_messages()
    |> Enum.take(-@history_window)
  end

  defp message_to_map(%Message{} = msg) do
    %{
      id: msg.id,
      role: msg.role,
      content: msg.content,
      tool_calls: msg.tool_calls,
      tool_results: msg.tool_results,
      inserted_at: msg.inserted_at
    }
  end

  defp stream_from_handle(%ReqLLM.StreamResponse{stream: stream}), do: stream
  defp stream_from_handle(%{stream: stream}), do: stream
  defp stream_from_handle(stream) when is_function(stream), do: stream
  defp stream_from_handle(stream), do: stream

  defp cancel_handle(handle) do
    try do
      llm_client().stop(handle)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp broadcast(session_id, payload) do
    Phoenix.PubSub.broadcast(AdButler.PubSub, "chat:#{session_id}", payload)
  end

  defp llm_client do
    Application.get_env(:ad_butler, :chat_llm_client, AdButler.Chat.LLMClient)
  end
end
