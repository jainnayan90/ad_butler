defmodule AdButler.Chat.Agent do
  @moduledoc """
  Jido 2.2 agent module for one chat session. Holds the conversation state
  the LLM needs to drive a turn — `session_id`, `user_id`, optional
  `ad_account_id`, recent message history (capped at the replay window),
  and per-turn `step_count` for the ReAct loop cap.

  This is the "think" side per Jido's split: pure decision logic. The
  matching `Chat.Server` is the "act" side that owns the AgentServer
  process, streams chunks to PubSub, persists messages, and counts tool
  calls. Real ReAct routing lands in W9D5 once tools exist.

  ## State

  Schema is Zoi-validated at compile time via `use Jido.Agent`:

    * `session_id` — the chat session UUID; required.
    * `user_id` — owning user UUID; required (drives tool re-scoping).
    * `ad_account_id` — optional account pin; `nil` = cross-account.
    * `history` — last N messages loaded from `chat_messages` on init;
      a list of plain maps (not `%Message{}` structs — keep state
      serialisable for Jido's RuntimeStore checkpointing).
    * `step_count` — tool calls used in the current turn; reset at the
      start of each user message; the cap (`@max_tool_calls_per_turn`)
      lives on `Chat.Server`, not here.

  Domain state lives at `agent.state.<field>` per Jido 2.2 (see
  `.claude/plans/week9-chat-foundation/scratchpad.md` D-W9-02).
  """

  use Jido.Agent,
    name: "ad_butler_chat_agent",
    description: "Per-session chat agent — owns conversation history and step count.",
    schema: [
      session_id: [type: :string, required: true],
      user_id: [type: :string, required: true],
      ad_account_id: [type: {:or, [:string, nil]}, default: nil],
      history: [type: {:list, :map}, default: []],
      step_count: [type: :integer, default: 0]
    ]
end
