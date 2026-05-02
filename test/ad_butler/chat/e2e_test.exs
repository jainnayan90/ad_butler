defmodule AdButler.Chat.E2ETest do
  @moduledoc """
  End-to-end exercise of the chat foundation: a scripted LLM walks the
  agent through a tool-using turn, and we assert on the persisted
  messages, the absence of write-tool side effects, and the telemetry
  bridge into `llm_usage`.

  Tagged `:integration` so the regular `mix test` run skips it. Run with:
      mix test --include integration test/ad_butler/chat/e2e_test.exs
  """
  use AdButler.DataCase, async: false

  @moduletag :integration

  import AdButler.Factory
  import Mox

  alias AdButler.Chat
  alias AdButler.Chat.{LLMClientMock, Server, Telemetry}
  alias AdButler.LLM.Usage
  alias AdButler.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Repo.query!("SELECT create_insights_partition((CURRENT_DATE)::DATE)")

    on_exit(fn ->
      Telemetry.clear_context()
      Telemetry.detach()
    end)

    :ok
  end

  defp insert_ad_with_finding(user) do
    mc = insert(:meta_connection, user: user)
    ad_account = insert(:ad_account, meta_connection: mc)
    campaign = insert(:campaign, ad_account: ad_account)
    ad_set = insert(:ad_set, ad_account: ad_account, campaign: campaign)
    ad = insert(:ad, ad_account: ad_account, ad_set: ad_set)

    finding =
      insert(:finding,
        ad_id: ad.id,
        ad_account_id: ad_account.id,
        kind: "creative_fatigue",
        severity: "high",
        title: "CTR has dropped 40% over 7 days"
      )

    {ad, finding}
  end

  defp tool_call_chunk(name, args) do
    %ReqLLM.StreamChunk{type: :tool_call, name: name, arguments: args}
  end

  defp content_chunk(text) do
    %ReqLLM.StreamChunk{type: :content, text: text}
  end

  defp meta_terminal do
    %ReqLLM.StreamChunk{type: :meta, metadata: %{terminal?: true}}
  end

  defp stub_response(chunks) do
    %ReqLLM.StreamResponse{
      stream: chunks,
      cancel: fn -> :ok end,
      context: nil,
      model: nil,
      metadata_handle: nil
    }
  end

  defp emit_token_usage_chunks(input_tokens, output_tokens) do
    fn ->
      :telemetry.execute(
        [:req_llm, :token_usage],
        %{
          tokens: %{
            input_tokens: input_tokens,
            output_tokens: output_tokens,
            cached_tokens: 0
          },
          cost: 0.0023,
          total_cost: 0.0023,
          input_cost: 0.0010,
          output_cost: 0.0013,
          reasoning_cost: 0.0
        },
        %{provider: :anthropic, model: %{id: "claude-sonnet-4-6"}, operation: :chat}
      )
    end
  end

  test "scripted multi-turn tool use produces a final assistant message + telemetry row" do
    user = insert(:user)
    {ad, finding} = insert_ad_with_finding(user)
    {:ok, session} = Chat.create_session(%{user_id: user.id})

    # Subscribe BEFORE the cast so PubSub deltas are not racy. The Server
    # broadcasts synchronously inside `handle_call` before the GenServer
    # reply, so the subscription must be in place before send_user_message.
    Phoenix.PubSub.subscribe(AdButler.PubSub, "chat:" <> session.id)

    # Set up the LLM script:
    # call 1 → tool_call: get_findings
    # call 2 → tool_call: get_ad_health
    # call 3 → final assistant text mentioning the finding id
    #
    # Each stub also synthesises a [:req_llm, :token_usage] event to mimic
    # what real ReqLLM emits at the end of a request — that's the signal
    # `Chat.Telemetry` translates into an `llm_usage` row.

    LLMClientMock
    |> expect(:stream, fn _messages, _opts ->
      emit_token_usage_chunks(100, 30).()
      {:ok, stub_response([tool_call_chunk("get_findings", %{"limit" => 5}), meta_terminal()])}
    end)
    |> expect(:stream, fn messages, _opts ->
      # Second stream call follows a tool turn — the prior tool result MUST
      # thread through into the LLM context window or the agent loses state.
      assert Enum.any?(messages, &(&1.role == "tool")),
             "expected the prior tool turn's result to thread through into the next stream call"

      emit_token_usage_chunks(120, 40).()

      {:ok,
       stub_response([
         tool_call_chunk("get_ad_health", %{"ad_id" => ad.id}),
         meta_terminal()
       ])}
    end)
    |> expect(:stream, fn messages, _opts ->
      assert Enum.any?(messages, &(&1.role == "tool")),
             "expected the prior tool turn's result to thread through into the next stream call"

      emit_token_usage_chunks(150, 60).()

      {:ok,
       stub_response([
         content_chunk("Found high-severity finding "),
         content_chunk(finding.id),
         content_chunk(" — CTR dropped 40%."),
         meta_terminal()
       ])}
    end)

    stub(LLMClientMock, :stop, fn _ -> :ok end)

    Telemetry.attach()

    {:ok, _pid} = Chat.ensure_server(user.id, session.id)
    assert :ok = Server.send_user_message(session.id, "Why is my account underperforming?")

    # PubSub: at least one chat_chunk (streaming-broadcast path) and a
    # turn_complete terminal.
    assert_receive {:chat_chunk, session_id, _delta}, 500
    assert session_id == session.id
    assert_receive {:turn_complete, ^session_id, _msg_id}, 500

    # Assertions
    messages = Chat.list_messages(session.id)
    roles = Enum.map(messages, & &1.role)

    assert "user" in roles, "expected a user message"
    assert "tool" in roles, "expected at least one tool message (read tool result)"
    assert "assistant" in roles, "expected a final assistant message"

    assistant_msg = Enum.find(messages, &(&1.role == "assistant"))
    assert assistant_msg.content =~ finding.id
    assert is_binary(assistant_msg.request_id)

    # No write-tool side effects (read tools only this turn).
    actions =
      Repo.all(
        from a in AdButler.Chat.ActionLog,
          where: a.user_id == ^user.id
      )

    assert actions == []

    # Telemetry bridge wrote three llm_usage rows — one per LLM call —
    # all scoped to this user, with the assistant message's request_id
    # matching the final row.
    usages =
      Repo.all(
        from u in Usage,
          where: u.user_id == ^user.id,
          order_by: [asc: u.inserted_at]
      )

    assert length(usages) == 3
    assert Enum.all?(usages, &(&1.provider == "anthropic"))
    assert Enum.all?(usages, &(&1.conversation_id == session.id))

    final_usage = List.last(usages)
    assert final_usage.request_id == assistant_msg.request_id
    assert final_usage.input_tokens == 150
    assert final_usage.output_tokens == 60
  end
end
