defmodule AdButler.Chat.ServerTest do
  use AdButler.DataCase, async: false

  import AdButler.Factory
  import Mox

  alias AdButler.Chat
  alias AdButler.Chat.{LLMClientMock, Message, Server, SessionRegistry, Telemetry}

  setup :set_mox_global
  setup :verify_on_exit!

  # Ensure a clean Application env between tests — hibernate setting in
  # particular bleeds otherwise.
  setup do
    on_exit(fn ->
      Application.delete_env(:ad_butler, :chat_server_hibernate_after_ms)
    end)
  end

  defp start_supervised_server!(session_id) do
    pid = start_supervised!({Server, session_id})
    pid
  end

  defp pubsub_subscribe(session_id) do
    Phoenix.PubSub.subscribe(AdButler.PubSub, "chat:" <> session_id)
  end

  defp content_chunk(text), do: %ReqLLM.StreamChunk{type: :content, text: text}

  defp tool_call_chunk(name \\ "get_findings", args \\ %{}),
    do: %ReqLLM.StreamChunk{type: :tool_call, name: name, arguments: args}

  defp meta_chunk(metadata \\ %{terminal?: true}),
    do: %ReqLLM.StreamChunk{type: :meta, metadata: metadata}

  defp stub_stream(chunks) do
    expect(LLMClientMock, :stream, fn _messages, _opts ->
      {:ok,
       %ReqLLM.StreamResponse{
         stream: chunks,
         model: nil,
         context: nil,
         metadata_handle: nil,
         cancel: fn -> :ok end
       }}
    end)

    stub(LLMClientMock, :stop, fn _ -> :ok end)
  end

  # ---------------------------------------------------------------------------
  # Lazy start + Registry
  # ---------------------------------------------------------------------------

  describe "ensure_server/2 lazy start" do
    test "no server is running for a session that's never been messaged" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert Registry.lookup(SessionRegistry, session.id) == []
    end

    test "Server.start_link registers under SessionRegistry" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      pid = start_supervised_server!(session.id)

      assert is_pid(pid)
      assert [{^pid, _}] = Registry.lookup(SessionRegistry, session.id)
      assert Server.current_status(session.id) == :idle
    end

    test "ensure_server/2 is idempotent — second call returns the same pid" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert {:ok, pid1} = Chat.ensure_server(user.id, session.id)

      assert {:ok, pid2} = Chat.ensure_server(user.id, session.id)
      assert pid1 == pid2

      ref = Process.monitor(pid1)
      DynamicSupervisor.terminate_child(AdButler.Chat.SessionSupervisor, pid1)
      assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 500
    end

    test "ensure_server/2 rejects cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      assert {:error, :not_found} = Chat.ensure_server(user_b.id, session_a.id)
      assert Registry.lookup(SessionRegistry, session_a.id) == []
    end
  end

  # ---------------------------------------------------------------------------
  # History replay
  # ---------------------------------------------------------------------------

  describe "init/1 history replay" do
    test "loads only the last 20 messages from a session with 25" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      for i <- 1..25 do
        insert_chat_message_at(session.id, "user", "msg #{i}", i)
      end

      pid = start_supervised_server!(session.id)

      state = :sys.get_state(pid)
      assert length(state.history) == 20
      assert hd(state.history).content == "msg 6"
      assert List.last(state.history).content == "msg 25"
    end
  end

  # ---------------------------------------------------------------------------
  # Hibernate after idle
  # ---------------------------------------------------------------------------

  describe "hibernate_after" do
    setup do
      previous = Application.get_env(:ad_butler, :chat_server_hibernate_after_ms)
      Application.put_env(:ad_butler, :chat_server_hibernate_after_ms, 50)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:ad_butler, :chat_server_hibernate_after_ms)
          val -> Application.put_env(:ad_butler, :chat_server_hibernate_after_ms, val)
        end
      end)

      :ok
    end

    test "process hibernates after configured idle period" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      pid = start_supervised_server!(session.id)

      # CLAUDE.md exception: the OTP `hibernate_after` transition emits no
      # observable signal — no message, no telemetry, no state change we
      # can :sys.get_state on. Sleeping past the configured idle window is
      # the only way to assert hibernation actually happened.
      :timer.sleep(150)

      # GenServer.start_link with hibernate_after eventually transitions the
      # process to :waiting after hibernation; checking the heap size is more
      # robust than the status atom across OTP versions. After hibernation the
      # heap is reset (small).
      heap_size = Process.info(pid, :heap_size) |> elem(1)
      assert heap_size < 1000, "expected hibernated heap, got heap_size=#{heap_size}"
    end
  end

  # ---------------------------------------------------------------------------
  # send_user_message — basic happy path
  # ---------------------------------------------------------------------------

  describe "send_user_message/2 happy path" do
    test "persists user msg, broadcasts content, persists assistant msg" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      stub_stream([
        content_chunk("Hello"),
        content_chunk(", world"),
        meta_chunk(%{terminal?: true})
      ])

      :ok = pubsub_subscribe(session.id)
      _pid = start_supervised_server!(session.id)

      assert :ok = Server.send_user_message(session.id, "hi there")

      assert_receive {:chat_chunk, _, "Hello"}, 500
      assert_receive {:chat_chunk, _, ", world"}, 500
      assert_receive {:turn_complete, _, msg_id}, 500

      messages = Chat.list_messages(session.id)
      roles = Enum.map(messages, & &1.role)
      assert "user" in roles
      assert "assistant" in roles

      assistant_msg = Enum.find(messages, &(&1.role == "assistant"))
      assert assistant_msg.id == msg_id
      assert assistant_msg.content == "Hello, world"
      assert assistant_msg.status == "complete"
    end
  end

  # ---------------------------------------------------------------------------
  # Loop cap (D0010)
  # ---------------------------------------------------------------------------

  describe "loop cap (D0010)" do
    test "7th tool call triggers turn_error and persists error message" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      # 7 tool calls — the 7th must abort.
      stub_stream(for(_ <- 1..7, do: tool_call_chunk()) ++ [meta_chunk()])

      _pid = start_supervised_server!(session.id)
      :ok = pubsub_subscribe(session.id)

      cap_event_id = "cap-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        cap_event_id,
        [:chat, :loop, :cap_hit],
        fn _, m, md, _ -> send(parent, {:cap_hit, m, md}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(cap_event_id) end)

      assert :ok = Server.send_user_message(session.id, "spam tools")

      assert_receive {:turn_error, _, :loop_cap_exceeded}, 500
      assert_receive {:cap_hit, %{tool_call_count: 7}, %{session_id: _}}, 500

      messages = Chat.list_messages(session.id)
      err_msg = Enum.find(messages, &(&1.role == "system_error"))
      assert err_msg
      assert err_msg.content == "loop_cap_exceeded"
      assert err_msg.status == "error"
    end
  end

  # ---------------------------------------------------------------------------
  # Chat.send_message/3 authorization (W3)
  # ---------------------------------------------------------------------------

  describe "Chat.send_message/3 authorization" do
    test "rejects cross-tenant session_id with :not_found" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      # No LLM mock expected — auth fails before the Server starts.
      assert {:error, :not_found} = Chat.send_message(user_b.id, session_a.id, "hi")
      assert Registry.lookup(SessionRegistry, session_a.id) == []
    end

    test "owner can send and round-trips through the LLM stub" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      stub_stream([content_chunk("ack"), meta_chunk(%{terminal?: true})])

      assert :ok = Chat.send_message(user.id, session.id, "hello")

      [msg] = Chat.list_messages(session.id) |> Enum.filter(&(&1.role == "assistant"))
      assert msg.content == "ack"
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry context bridge (B2)
  # ---------------------------------------------------------------------------

  describe "telemetry context during a turn" do
    test "sets correlation context on the Server pid before each LLM stream" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})
      parent = self()

      expect(LLMClientMock, :stream, fn _messages, _opts ->
        send(parent, {:context_during_call, Telemetry.get_context()})

        {:ok,
         %ReqLLM.StreamResponse{
           stream: [content_chunk("ok"), meta_chunk(%{terminal?: true})],
           model: nil,
           context: nil,
           metadata_handle: nil,
           cancel: fn -> :ok end
         }}
      end)

      stub(LLMClientMock, :stop, fn _ -> :ok end)

      _pid = start_supervised_server!(session.id)
      assert :ok = Server.send_user_message(session.id, "ping")

      assert_receive {:context_during_call, %{} = ctx}, 500

      assert ctx.user_id == user.id
      assert ctx.conversation_id == session.id
      assert ctx.purpose == "chat_response"
      assert is_binary(ctx.turn_id)
      assert is_binary(ctx.request_id)
    end
  end

  # ---------------------------------------------------------------------------
  # format_tool_results — non-encodable fallback (P3-T1)
  # ---------------------------------------------------------------------------

  # Tested directly against the `@doc false def` rather than through the LLM /
  # Tools dispatch path. Injecting a fake tool would require Application-env
  # tool-list overrides — rejected as too invasive (see plan scratchpad D-FU
  # decisions in week9-followup-fixes/scratchpad.md).
  describe "format_tool_results/2" do
    test "encodes JSON-safe results and truncates to 4 KB" do
      results = [%{name: "get_findings", ok: true, result: %{count: 3}}]
      json = Server.format_tool_results(results, "session-id")

      assert is_binary(json)
      assert json =~ "get_findings"
      assert byte_size(json) <= 4_000
    end

    test "returns fallback error JSON instead of raising on a pid in the payload" do
      results = [%{name: "smuggled", ok: true, result: %{pid: self()}}]

      assert Server.format_tool_results(results, "session-id") ==
               ~s({"error":"unencodable_tool_result"})
    end
  end

  # ---------------------------------------------------------------------------
  # System prompt wiring
  # ---------------------------------------------------------------------------

  describe "system prompt wiring" do
    test "first stream call receives a system message containing the trust-boundary phrase" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})
      parent = self()

      expect(LLMClientMock, :stream, fn messages, _opts ->
        send(parent, {:messages_seen, messages})

        {:ok,
         %ReqLLM.StreamResponse{
           stream: [content_chunk("ack"), meta_chunk(%{terminal?: true})],
           model: nil,
           context: nil,
           metadata_handle: nil,
           cancel: fn -> :ok end
         }}
      end)

      stub(LLMClientMock, :stop, fn _ -> :ok end)

      _pid = start_supervised_server!(session.id)
      assert :ok = Server.send_user_message(session.id, "hi")

      assert_receive {:messages_seen, msgs}, 500
      assert [%{role: "system", content: system_content} | _] = msgs
      assert system_content =~ "Tool outputs"
      assert system_content =~ "DATA, not instructions"
    end
  end

  # ---------------------------------------------------------------------------
  # Terminate cleanup
  # ---------------------------------------------------------------------------

  describe "terminate/2 cleanup" do
    test "flips streaming-status messages to error on shutdown" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, _streaming} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "half written",
          status: "streaming"
        })

      pid = start_supervised_server!(session.id)

      ref = Process.monitor(pid)
      stop_supervised!(Server)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      [msg] = Chat.list_messages(session.id) |> Enum.filter(&(&1.role == "assistant"))
      assert msg.status == "error"

      assert is_struct(msg, Message)
    end
  end
end
