---
module: "AdButler.Chat.Server, AdButlerWeb.ChatLive.Show, AdButler.Chat.LogRedactor"
date: "2026-05-02"
problem_type: anti_pattern
component: logging
symptoms:
  - "Logger.error/warning metadata field `reason` echoes raw LLM provider error bodies into structured logs"
  - "Ecto.Changeset error reasons from append_message carry the user's raw chat body in changeset.changes.content"
  - "start_async exit reasons from a crashed Chat.Server can include stacktrace frames containing prompt fragments"
  - "Log aggregator (Loki/Datadog) ends up with searchable, queryable user PII it should never have stored"
root_cause: "Free-form `reason` terms from third-party LLM clients (Req/ReqLLM error tuples), Ecto changesets (whose `.changes` carries user-supplied text), and `start_async {:exit, reason}` shapes routinely embed user-content-bearing payloads. Passing them as raw Logger metadata means the structured-logging pipeline serializes the WHOLE term — including the user's chat message — into the indexed metadata field. The fix is a tiny pure helper that reduces any term to a non-content-bearing tag (atom or `:unknown`) before the Logger call."
severity: high
tags: [logging, observability, security, pii, llm, redaction, chat, ecto-changeset, ad-butler]
---

# LLM error `reason` Leaks User Content into Structured Logs

## Symptoms

A chat-flow Logger call structured-logs the raw `reason` term:

```elixir
Logger.error("chat: LLM stream failed",
  session_id: state.session_id,
  reason: reason
)
```

`reason` here is whatever the LLM client returned: typically a tuple
like `{:error, %{body: "<the user's prompt verbatim>"}}` from a 4xx
response, or an `%Req.TransportError{}` struct, or a raw exception
struct from a `:exit`.

The downstream log aggregator indexes `reason` as a string field
containing the whole term — including the user's chat message,
prompt fragments, and any PII the user typed. Operations engineers
querying for `reason="rate_limited"` end up surfacing other users'
private chats.

The same anti-pattern appears in `Chat.Server`'s
`persist_user_message` error path (changeset errors carry
`changes: %{content: <user body>}`) and `persist_assistant` error
path (changeset errors carry the model's content output, which can
echo prompt fragments).

The same anti-pattern appears in `ChatLive.Show`'s `handle_async`
clauses: `start_async` `{:exit, reason}` shapes are 3-tuples whose
second element is often a stack-traced exception holding the
arguments to the failed function — i.e. the user's chat body.

## Root Cause

Three classes of `reason` term flow through chat error paths:

1. **LLM client errors** — `{:error, %{body: <user-content-echoed>, status: ...}}`
   from Req/ReqLLM. Many providers echo back the offending request
   in 4xx response bodies.
2. **Ecto changeset errors** — `%Ecto.Changeset{changes: %{content: body}}`
   carries the user's raw body in `.changes`.
3. **`start_async` exit reasons** — `{:exit, {%RuntimeError{message: ...}, [stack]}}` —
   stack frames include the function arguments at the crash point,
   which for `Chat.send_message/3` are `(user_id, session_id, body)`.

Logger metadata is not a content-redaction boundary — passing the
raw term means the whole term goes into the indexed log payload.
PII filters in log aggregators don't help because the structure
(map keys like `body`, `content`, `arguments`) is generic; pattern-
matching every variant in the aggregator is impractical.

## Fix

Lift redaction to a tiny pure helper that reduces any term to a
non-content-bearing tag, and call it at every Logger metadata site
that handles a free-form `reason` term:

```elixir
# lib/ad_butler/chat/log_redactor.ex
defmodule AdButler.Chat.LogRedactor do
  @moduledoc """
  Reduces a free-form term to a non-content-bearing tag suitable
  for structured logging metadata.
  """

  @doc """
  Reduces `reason` to a safe tag.

    * Atoms pass through unchanged.
    * Tagged tuples reduce to their leading atom.
    * Anything else collapses to `:unknown`.
  """
  @spec redact(term()) :: atom()
  def redact(reason) when is_atom(reason), do: reason
  def redact({tag, _}) when is_atom(tag), do: tag
  def redact({tag, _, _}) when is_atom(tag), do: tag
  def redact(_), do: :unknown
end
```

Apply at every Logger metadata call site that handles `reason`:

```elixir
# lib/ad_butler/chat/server.ex
Logger.error("chat: LLM stream failed",
  session_id: state.session_id,
  reason: LogRedactor.redact(reason)   # was `reason: reason`
)
```

Same treatment for:

- `persist_user_message` error log (changeset.changes.content is
  the raw user body)
- `persist_assistant` error log (changeset.changes.content is the
  model's content output — can still echo prompt fragments)
- `ChatLive.Show.handle_async {:ok, {:error, _}}` (`{:error, reason}`
  from `Chat.send_message`)
- `ChatLive.Show.handle_async {:exit, _}` (3-tuple exit reason)
- `ChatLive.Show.handle_info {:turn_error, _, reason}` (PubSub
  payload from `Chat.Server`'s LLM error path — reason is the
  raw provider error, not yet redacted at the broadcast site)

## Why a tiny module, not inline pattern matches

A single inline `case`/`with` per call site duplicates the redact
rules and drifts when a new shape (e.g. arity-4 tuple from a future
client library) appears. Centralizing it means one place to extend.

The module's docstring explicitly says **"never round-trip the
redacted value back to a user-facing channel — it is intentionally
lossy"** to prevent a future caller from mistaking the redacted tag
for a useful payload.

## Test pattern

`LogRedactor.redact/1` is pure and `async: true`-friendly. Cover
the documented contract:

```elixir
test "passes atoms through unchanged" do
  assert LogRedactor.redact(:timeout) == :timeout
end

test "reduces a 2-tuple with an atom tag to the tag" do
  assert LogRedactor.redact({:dns_error, "user-content-leak"}) == :dns_error
end

test "collapses content-bearing strings to :unknown" do
  assert LogRedactor.redact("HTTP 429 — please retry") == :unknown
end

test "collapses tuples with non-atom tags to :unknown" do
  assert LogRedactor.redact({"dns_error", "leak"}) == :unknown
end
```

## Related

- `.claude/solutions/logging/structured-logger-inspect-defeats-aggregation-20260430.md` — same family of "Logger metadata is not a free-form playground" rule, complementary
- CLAUDE.md "Logging and Observability" — the project's structured-KV rule
- AdButler.Log.redact/1 — already exists for external API responses; this redactor is for free-form `reason` terms specifically
