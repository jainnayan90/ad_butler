defmodule AdButler.ChatTest do
  use AdButler.DataCase, async: true

  import AdButler.Factory

  alias AdButler.Chat
  alias AdButler.Chat.{ActionLog, Message, Session}

  # ---------------------------------------------------------------------------
  # Sessions — create / get
  # ---------------------------------------------------------------------------

  describe "create_session/1" do
    test "creates a session for the given user with last_activity_at set" do
      user = insert(:user)

      assert {:ok, %Session{} = session} = Chat.create_session(%{user_id: user.id})
      assert session.user_id == user.id
      assert session.status == "active"
      assert %DateTime{} = session.last_activity_at
    end

    test "rejects unknown status values" do
      user = insert(:user)

      assert {:error, changeset} =
               Chat.create_session(%{user_id: user.id, status: "frozen"})

      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "requires user_id" do
      assert {:error, changeset} = Chat.create_session(%{})
      assert %{user_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "get_session!/2 and get_session/2 tenant isolation" do
    test "get_session!/2 raises on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      assert_raise Ecto.NoResultsError, fn ->
        Chat.get_session!(user_b.id, session_a.id)
      end
    end

    test "get_session!/2 returns the session for the owner" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert %Session{id: id} = Chat.get_session!(user.id, session.id)
      assert id == session.id
    end

    test "get_session/2 returns :not_found on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      assert {:error, :not_found} = Chat.get_session(user_b.id, session_a.id)
    end

    test "get_session/2 returns :not_found on a syntactically-invalid UUID" do
      user = insert(:user)
      assert {:error, :not_found} = Chat.get_session(user.id, "not-a-uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # Sessions — list / paginate
  # ---------------------------------------------------------------------------

  describe "list_sessions/2 and paginate_sessions/2 tenant isolation" do
    test "user_b cannot see user_a's sessions" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, _} = Chat.create_session(%{user_id: user_a.id})

      assert Chat.list_sessions(user_b.id) == []
      assert {[], 0} = Chat.paginate_sessions(user_b.id)
    end

    test "list_sessions/2 returns sessions ordered by recency" do
      user = insert(:user)
      now = DateTime.utc_now()

      {:ok, older} =
        Chat.create_session(%{
          user_id: user.id,
          last_activity_at: DateTime.add(now, -10, :second)
        })

      {:ok, newer} =
        Chat.create_session(%{user_id: user.id, last_activity_at: now})

      assert [first, second] = Chat.list_sessions(user.id)
      assert first.id == newer.id
      assert second.id == older.id
    end

    test "paginate_sessions/2 returns {items, total} and respects per_page" do
      user = insert(:user)
      now = DateTime.utc_now()

      for offset <- 1..3 do
        {:ok, _} =
          Chat.create_session(%{
            user_id: user.id,
            last_activity_at: DateTime.add(now, offset, :second)
          })
      end

      {items, total} = Chat.paginate_sessions(user.id, page: 1, per_page: 2)
      assert length(items) == 2
      assert total == 3
    end

    test "paginate_sessions/2 filters by status" do
      user = insert(:user)
      {:ok, active} = Chat.create_session(%{user_id: user.id})
      {:ok, _archived} = Chat.create_session(%{user_id: user.id, status: "archived"})

      {items, total} = Chat.paginate_sessions(user.id, status: "active")
      assert total == 1
      assert [%Session{id: id}] = items
      assert id == active.id
    end
  end

  # ---------------------------------------------------------------------------
  # Messages — append / paginate
  # ---------------------------------------------------------------------------

  describe "append_message/1" do
    test "inserts the message and bumps the session's last_activity_at" do
      user = insert(:user)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      {:ok, session} =
        Chat.create_session(%{user_id: user.id, last_activity_at: past})

      original_activity = session.last_activity_at

      assert {:ok, %Message{role: "user", content: "hi"}} =
               Chat.append_message(%{
                 chat_session_id: session.id,
                 role: "user",
                 content: "hi"
               })

      reloaded = Chat.get_session!(user.id, session.id)
      assert DateTime.compare(reloaded.last_activity_at, original_activity) == :gt
    end

    test "rejects unknown roles" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert {:error, changeset} =
               Chat.append_message(%{
                 chat_session_id: session.id,
                 role: "alien",
                 content: "x"
               })

      assert %{role: ["is invalid"]} = errors_on(changeset)
    end

    test "permits a tool message without content" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert {:ok, %Message{role: "tool"}} =
               Chat.append_message(%{
                 chat_session_id: session.id,
                 role: "tool",
                 tool_results: [%{"name" => "get_findings", "ok" => true}]
               })
    end

    test "requires content for non-tool roles" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert {:error, changeset} =
               Chat.append_message(%{chat_session_id: session.id, role: "user"})

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "request_id partial unique index" do
    test "rejects a second assistant message with the same request_id" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})
      request_id = Ecto.UUID.generate()

      {:ok, _first} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "first",
          request_id: request_id
        })

      assert_raise Ecto.ConstraintError,
                   ~r/chat_messages_request_id_unique_when_present/,
                   fn ->
                     Chat.append_message(%{
                       chat_session_id: session.id,
                       role: "assistant",
                       content: "second",
                       request_id: request_id
                     })
                   end
    end

    test "rejects a second tool message with the same request_id (role-agnostic index)" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})
      request_id = Ecto.UUID.generate()

      {:ok, _first} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "tool",
          tool_results: [%{"name" => "get_findings", "ok" => true}],
          request_id: request_id
        })

      assert_raise Ecto.ConstraintError,
                   ~r/chat_messages_request_id_unique_when_present/,
                   fn ->
                     Chat.append_message(%{
                       chat_session_id: session.id,
                       role: "tool",
                       tool_results: [%{"name" => "get_findings", "ok" => true}],
                       request_id: request_id
                     })
                   end
    end

    test "permits multiple messages with nil request_id (partial index)" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, _} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "user",
          content: "first"
        })

      {:ok, _} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "user",
          content: "second"
        })
    end
  end

  describe "list_messages/2 and paginate_messages/2" do
    test "list_messages/2 returns chronological order" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      m1 = insert_chat_message_at(session.id, "user", "first", 1)
      m2 = insert_chat_message_at(session.id, "assistant", "second", 2)

      assert [a, b] = Chat.list_messages(session.id)
      assert a.id == m1.id
      assert b.id == m2.id
    end

    test "paginate_messages/2 returns {items, total} and walks pages" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      for i <- 1..5 do
        insert_chat_message_at(session.id, "user", "msg #{i}", i)
      end

      {page1, total} = Chat.paginate_messages(session.id, page: 1, per_page: 3)
      assert length(page1) == 3
      assert total == 5

      {page2, ^total} = Chat.paginate_messages(session.id, page: 2, per_page: 3)
      assert length(page2) == 2
      page1_ids = Enum.map(page1, & &1.id)
      page2_ids = Enum.map(page2, & &1.id)
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
    end

    test "list_messages/2 is not tenant-scoped — caller must authorise upstream" do
      # The function is keyed on session_id only by design (faster reads,
      # session was already authorised via get_session/2). This test
      # documents that contract: a caller passing session_a.id from user_b's
      # process gets back user_a's messages — authorisation is the caller's
      # responsibility.
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})
      {:ok, session_b} = Chat.create_session(%{user_id: user_b.id})

      {:ok, _} =
        Chat.append_message(%{
          chat_session_id: session_a.id,
          role: "user",
          content: "for user_a"
        })

      assert [%Message{content: "for user_a"}] = Chat.list_messages(session_a.id)
      assert [] = Chat.list_messages(session_b.id)
    end
  end

  # ---------------------------------------------------------------------------
  # flip_streaming_messages_to_error/1
  # ---------------------------------------------------------------------------

  describe "flip_streaming_messages_to_error/1" do
    test "flips streaming rows to error" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, streaming} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "half",
          status: "streaming"
        })

      assert {:ok, 1} = Chat.unsafe_flip_streaming_messages_to_error(session.id)

      [reloaded] =
        Chat.list_messages(session.id) |> Enum.filter(&(&1.id == streaming.id))

      assert reloaded.status == "error"
    end

    test "leaves complete and error rows untouched" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, complete} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "user",
          content: "done",
          status: "complete"
        })

      {:ok, errored} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "assistant",
          content: "boom",
          status: "error"
        })

      assert {:ok, 0} = Chat.unsafe_flip_streaming_messages_to_error(session.id)

      reloaded = Chat.list_messages(session.id)
      assert Enum.find(reloaded, &(&1.id == complete.id)).status == "complete"
      assert Enum.find(reloaded, &(&1.id == errored.id)).status == "error"
    end

    test "is idempotent on a clean session" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert {:ok, 0} = Chat.unsafe_flip_streaming_messages_to_error(session.id)
      assert {:ok, 0} = Chat.unsafe_flip_streaming_messages_to_error(session.id)
    end

    test "scoped on session_id only — caller must authorise upstream" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})
      {:ok, session_b} = Chat.create_session(%{user_id: user_b.id})

      {:ok, _} =
        Chat.append_message(%{
          chat_session_id: session_a.id,
          role: "assistant",
          content: "user_a half",
          status: "streaming"
        })

      assert {:ok, 0} = Chat.unsafe_flip_streaming_messages_to_error(session_b.id)

      [a_msg] = Chat.list_messages(session_a.id)
      assert a_msg.status == "streaming"
    end
  end

  # ---------------------------------------------------------------------------
  # get_session_user_id/1
  # ---------------------------------------------------------------------------

  describe "get_session_user_id/1" do
    test "returns the user_id for an existing session" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert {:ok, uid} = Chat.unsafe_get_session_user_id(session.id)
      assert uid == user.id
    end

    test "returns :not_found for a missing session" do
      assert {:error, :not_found} =
               Chat.unsafe_get_session_user_id("00000000-0000-0000-0000-000000000000")
    end

    test "returns :not_found for a malformed UUID" do
      assert {:error, :not_found} = Chat.unsafe_get_session_user_id("not-a-uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # subscribe/1
  # ---------------------------------------------------------------------------

  describe "subscribe/1" do
    test "subscribes the caller to the session topic and receives broadcasts" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      assert :ok = Chat.subscribe(session.id)

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session.id,
        {:chat_chunk, session.id, "hello"}
      )

      assert_receive {:chat_chunk, sid, "hello"}, 200
      assert sid == session.id
    end

    test "topic isolation — broadcasting on one session's topic does not reach another's subscriber" do
      user = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user.id})
      {:ok, session_b} = Chat.create_session(%{user_id: user.id})

      assert :ok = Chat.subscribe(session_a.id)

      Phoenix.PubSub.broadcast(
        AdButler.PubSub,
        "chat:" <> session_b.id,
        {:chat_chunk, session_b.id, "for_b_only"}
      )

      refute_receive {:chat_chunk, _, "for_b_only"}, 100
    end
  end

  # ---------------------------------------------------------------------------
  # get_message!/2
  # ---------------------------------------------------------------------------

  describe "get_message!/2" do
    test "returns the message for an existing id scoped to the owner" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "user",
          content: "hi"
        })

      assert %Message{id: id, content: "hi"} = Chat.get_message!(user.id, msg.id)
      assert id == msg.id
    end

    test "raises Ecto.NoResultsError on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session_a.id,
          role: "user",
          content: "secret"
        })

      assert_raise Ecto.NoResultsError, fn ->
        Chat.get_message!(user_b.id, msg.id)
      end
    end

    test "raises Ecto.NoResultsError on a missing id" do
      user = insert(:user)

      assert_raise Ecto.NoResultsError, fn ->
        Chat.get_message!(user.id, "00000000-0000-0000-0000-000000000000")
      end
    end

    test "raises Ecto.NoResultsError on a malformed UUID (parity with get_session!/2)" do
      user = insert(:user)

      assert_raise Ecto.NoResultsError, fn ->
        Chat.get_message!(user.id, "not-a-uuid")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # get_message/2
  # ---------------------------------------------------------------------------

  describe "get_message/2" do
    test "returns {:ok, message} for the owner" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "user",
          content: "hi"
        })

      assert {:ok, %Message{id: id, content: "hi"}} = Chat.get_message(user.id, msg.id)
      assert id == msg.id
    end

    test "returns :not_found on cross-tenant access" do
      user_a = insert(:user)
      user_b = insert(:user)
      {:ok, session_a} = Chat.create_session(%{user_id: user_a.id})

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session_a.id,
          role: "user",
          content: "secret"
        })

      assert {:error, :not_found} = Chat.get_message(user_b.id, msg.id)
    end

    test "returns :not_found for a missing id" do
      user = insert(:user)

      assert {:error, :not_found} =
               Chat.get_message(user.id, "00000000-0000-0000-0000-000000000000")
    end

    test "returns :not_found for a malformed UUID" do
      user = insert(:user)
      assert {:error, :not_found} = Chat.get_message(user.id, "not-a-uuid")
    end
  end

  # ---------------------------------------------------------------------------
  # unsafe_update_message_tool_results/2
  # ---------------------------------------------------------------------------

  describe "unsafe_update_message_tool_results/2" do
    test "writes the JSONB array and returns the updated message" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "tool",
          tool_results: [%{"name" => "get_findings", "ok" => true}]
        })

      new_results = [
        %{"name" => "get_insights_series", "ok" => true, "rendered_svg" => "<svg/>"}
      ]

      assert {:ok, %Message{tool_results: ^new_results}} =
               Chat.unsafe_update_message_tool_results(msg.id, new_results)

      reloaded = Chat.get_message!(user.id, msg.id)
      assert reloaded.tool_results == new_results
    end

    test "returns :not_found for a missing id" do
      assert {:error, :not_found} =
               Chat.unsafe_update_message_tool_results(
                 "00000000-0000-0000-0000-000000000000",
                 []
               )
    end

    test "rejects non-list tool_results" do
      user = insert(:user)
      {:ok, session} = Chat.create_session(%{user_id: user.id})

      {:ok, msg} =
        Chat.append_message(%{
          chat_session_id: session.id,
          role: "user",
          content: "hi"
        })

      assert {:error, %Ecto.Changeset{}} =
               Chat.unsafe_update_message_tool_results(msg.id, %{"not" => "a list"})
    end
  end

  # ---------------------------------------------------------------------------
  # Action log
  # ---------------------------------------------------------------------------

  describe "record_action_log/1" do
    test "inserts an action log row" do
      user = insert(:user)

      assert {:ok, %ActionLog{} = log} =
               Chat.record_action_log(%{
                 user_id: user.id,
                 tool: "pause_ad",
                 outcome: "success",
                 args: %{"ad_id" => "abc"}
               })

      assert log.user_id == user.id
      assert log.outcome == "success"
    end

    test "rejects unknown outcome" do
      user = insert(:user)

      assert {:error, changeset} =
               Chat.record_action_log(%{
                 user_id: user.id,
                 tool: "pause_ad",
                 outcome: "maybe"
               })

      assert %{outcome: ["is invalid"]} = errors_on(changeset)
    end
  end
end
