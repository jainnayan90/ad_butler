# Triage — Week 9 Review-Fix Review

**Date**: 2026-05-02
**Source**: [week9-review-fixes-review.md](week9-review-fixes-review.md)
**Approach**: Just fix them (no per-finding guidance)

---

## Fix Queue (9 items)

### Auto-approved (Iron Law violations)

- [ ] **W1 [Iron Law]** — Add `:turn_id` and `:conversation_id` to the Logger metadata allowlist in [config/config.exs:88-143](config/config.exs#L88-L143). CLAUDE.md: unallowlisted metadata keys silently drop.
- [ ] **IL-W1 [Iron Law: never raise in happy path]** — Replace `Jason.encode!/1` with `Jason.encode/1 + fallback string` in `format_tool_results/1` at [server.ex:347-349](lib/ad_butler/chat/server.ex#L347-L349). Unencodable tool result currently crashes the GenServer.call.

### HIGH (defense-in-depth)

- [ ] **H-1** — Extend `mix check.unsafe_callers` alias in [mix.exs](mix.exs) so it also forbids `Chat\.unsafe_` outside the allowlist (`lib/ad_butler/chat/server.ex` only). Keep the existing `Ads.unsafe_` rule.
- [ ] **H-2** — Mark `Chat.Server.start_link/1` with `@doc false` at [server.ex:55-61](lib/ad_butler/chat/server.ex#L55-L61). Ensures every caller routes through the auth-gated `Chat.ensure_server/2`.

### WARN — Cheap bundle

- [ ] **W2** — Add `def decimal_to_float(_), do: nil` fall-through in [helpers.ex:45-48](lib/ad_butler/chat/tools/helpers.ex#L45-L48). Prevents `FunctionClauseError` mid-stream on unexpected input.
- [ ] **Sec W-1** — Add `redact: true` on `:request_id` in [chat/message.ex:32](lib/ad_butler/chat/message.ex#L32) and `LLM.Usage`. Add `"request_id"` to `:filter_parameters` in [config/config.exs:148](config/config.exs#L148). Prevents request_id leaking through Phoenix param logs / `inspect(message_struct)`.
- [ ] **Sec W-4** — Replace `%{"raw" => inspect(other)}` with `%{"error" => "unrecognised_tool_call_shape"}` at [server.ex:341-344](lib/ad_butler/chat/server.ex#L341-L344). `inspect/1` output landing in tenant-readable jsonb is the same anti-pattern banned in Logger metadata.

### WARN — Remaining

- [ ] **Sec W-3** — Add a partial unique index `WHERE request_id IS NOT NULL` on `chat_messages.request_id` via a new migration. Prevents future `llm_usage` join fan-out if `persist_assistant/3` ever retries.
- [ ] **Test W** — Verify the `chat_messages.inserted_at` column in the create_chat_messages migration is `timestamptz`/`utc_datetime_usec` (not second-precision). The schema declares `:utc_datetime_usec` — confirm migration matches so `insert_chat_message_at/4` sub-second offsets aren't truncated. Mark resolved by inspecting [priv/repo/migrations/20260501110604_create_chat_messages.exs](priv/repo/migrations/20260501110604_create_chat_messages.exs).

---

## Skipped / Deferred (5 SUGGESTIONs)

Defer all comment-only suggestions; not blocking and don't change behaviour:

- **S1 (elixir)** — `react_loop/3` try/after explanatory comment
- **IL-S1** — `normalise_params/1` rationale comment
- **Test S1** — Hibernate test heap-size assertion portability
- **Test S2** — e2e `emit_token_usage_chunks` process-coupling note
- **Test S3** — `chat_test.exs:226` cross-reference to `server_test.exs:243`

---

## Pre-existing (out of diff — not in this triage)

- **IL-W2** — Workers still wrap metadata in `inspect/1` (4 worker files + notifications.ex). Worth a separate cleanup task.
- **IL-S2 / elixir S2** — `CompareCreatives` N+1, already tracked by `# TODO(W11)`.
