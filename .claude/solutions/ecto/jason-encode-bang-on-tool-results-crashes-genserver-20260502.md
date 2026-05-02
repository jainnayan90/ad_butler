---
module: "AdButler.Chat.Server (and any GenServer that serializes user/agent-supplied data into jsonb)"
date: "2026-05-02"
problem_type: defensive_coding
component: chat_runtime
symptoms:
  - "`Chat.Server` GenServer crashes with `Protocol.UndefinedError: protocol Jason.Encoder not implemented for type PID` when a tool returns a result containing a pid/ref/function"
  - "Per-turn loop aborts mid-stream and the assistant message is never persisted; the LiveView shows a blank turn and a broken streaming row"
  - "Reviewer flags `Jason.encode!/1` in a hot path as a Iron Law violation — the happy path raises on data the agent doesn't fully control"
root_cause: "`Jason.encode!/1` raises on any term Jason cannot serialise (pids, refs, anonymous functions, custom structs without a derived encoder). Even though current tools return plain maps, the boundary contract is not enforced — a future tool, or a buggy tool returning a struct it forgot to derive Jason.Encoder for, brings down the per-session Server. The blast radius is the entire turn (history is reloaded from the DB on next start, but the in-flight assistant message persists with `status: \"streaming\"` until terminate flips it to error)."
severity: medium
tags: [genserver, jason, defensive-coding, chat, ad-butler, iron-law-2]
---

# `Jason.encode!/1` on Tool Results Crashes the Per-Session GenServer

## Symptoms

```
** (Protocol.UndefinedError) protocol Jason.Encoder not implemented for type PID.
   This protocol is implemented for the following type(s): Atom, BitString, ...
   (jason 1.4.4) lib/jason.ex:175: Jason.encode!/2
   (ad_butler 0.1.0) lib/ad_butler/chat/server.ex:348: ... format_tool_results/1
```

The Server `handle_call` callback raises, the supervisor restarts the
Server, a fresh `init/1` replays history, and any in-flight assistant turn
remains stuck on `status: "streaming"` until the next `terminate/2` flips
it to `error`. The user sees a partial chunk in the LiveView and then
silence; nothing renders the failure cause.

Same pattern applies wherever you serialise inbound data into jsonb: tool
results, webhook payloads, OAuth profile responses, anything where the
shape is governed by a contract you don't fully own.

## Root Cause

`Jason.encode!/1` raises on:

- pids, refs, ports
- anonymous functions
- structs without `@derive Jason.Encoder` or a custom impl
- atoms that Jason chooses to reject in strict mode (uncommon)

In a chat agent, tool results come from `Jido.Action` modules dispatched by
the LLM's tool-call instruction. The agent is the boundary — anything that
crosses it should be serialisable, but enforcing that today requires either:

1. Validating the result shape inside every tool (impractical), or
2. Catching the failure at the serialisation boundary (this fix).

The principle is the same as wrapping any third-party-shaped data: never
let one tool's bug crash the whole turn.

## Fix

Replace `Jason.encode!/1` with `Jason.encode/1` and a fallback string. Log
the failure with structured metadata so it shows up in observability without
leaking the unencodable term itself.

```elixir
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
```

The fallback is a fixed JSON string the LLM can read on its next turn — it
sees `{"error": "unencodable_tool_result"}` in the tool message slot and
can react ("I tried to call X but it returned an unprocessable result").

## Sibling Pattern: Don't `inspect/1` into jsonb

The same module had a fallback for unrecognised tool-call shapes:

```elixir
defp serialise_tool_call(other), do: %{"raw" => inspect(other)}
```

This persists `inspect(other)` (which can include user-typed strings or
agent hallucinations) into the `tool_calls` jsonb column. Replace with a
classifier that captures the shape without the contents:

```elixir
defp serialise_tool_call(other, session_id) do
  Logger.warning("chat: unrecognised tool_call shape",
    session_id: session_id,
    kind: kind_of(other)
  )

  %{"error" => "unrecognised_tool_call_shape"}
end

defp kind_of(term) when is_struct(term), do: term.__struct__ |> Atom.to_string()
defp kind_of(term) when is_map(term), do: "map"
defp kind_of(term) when is_atom(term), do: Atom.to_string(term)
defp kind_of(_), do: "other"
```

`kind_of/1` returns one of: `"map"`, the struct name, atom-as-string, or
`"other"` — none of which embed user-supplied content.

## Testing

`format_tool_results/2` becomes a public `@doc false` function so unit
tests can poke it directly without spinning up a stub LLM stream + a fake
tool that smuggles a pid:

```elixir
test "returns fallback error JSON instead of raising on a pid in the payload" do
  results = [%{name: "smuggled", ok: true, result: %{pid: self()}}]

  assert Server.format_tool_results(results, "session-id") ==
           ~s({"error":"unencodable_tool_result"})
end
```

## Prevention

- For any `Jason.encode!/1` call on data that crosses a process /
  third-party / agent boundary, switch to `Jason.encode/1` + fallback.
- Don't `inspect/1` into a persistent column. The output is opaque to
  filtering and may include sensitive material.
- Pair the encoder change with a test that uses a pid (or a `make_ref()`)
  as the offending term — it's the cheapest way to provoke the failure.

## Related

- `.claude/solutions/logging/structured-logger-inspect-defeats-aggregation-20260430.md`
  — same root principle (don't pre-stringify terms) applied to Logger
  metadata.
