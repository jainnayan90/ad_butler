# Security Review — Week 9 Review Fixes

No BLOCKERs. Two HIGH (defense-in-depth around the new `unsafe_` prefix). WARNs around `request_id` exposure and a small `inspect/1` artifact. Atom-DoS / SQL-injection / secret-leak / tenant-scope surface across changed files: clean.

---

## HIGH

### H-1 — `unsafe_*` prefix is documentation, not enforcement
`lib/ad_butler/chat.ex:138-146,261-272`

The plan's acceptance lists `mix check.unsafe_callers`. **Verification:** the alias DOES exist in `mix.exs` but is scoped to `Ads.unsafe_` only — it does NOT cover the new `Chat.unsafe_*` functions. Both functions are public `def` with `@spec` and verbose `@doc` — discoverable in HexDocs / IDE autocomplete. The rename helps grep but doesn't *prevent* misuse.

Pick one: (a) extend `mix check.unsafe_callers` to also forbid `Chat\.unsafe_` outside an allowlist (`lib/ad_butler/chat/server.ex` only); (b) move both into `AdButler.Chat.Internal`; (c) at minimum add `@doc false`. Do this before W11 broadens the call surface.

### H-2 — `Chat.Server.start_link/1` trusts its `session_id` arg
`lib/ad_butler/chat/server.ex:113-140`

`init/1` calls `Chat.unsafe_get_session_user_id(session_id)` with whatever was passed to `start_link/1`. Only caller today is the auth-gated `start_or_lookup_server/1`, so not exploitable now — but `start_link/1` is publicly `@spec`'d. A future test helper / console / supervisor wiring that bypasses `ensure_server/2` would silently hydrate any tenant's last-20 messages into `state.history`. Fix: mark `start_link/1` `@doc false` and route every call through `ensure_server/2`, or pass `{user_id, session_id}` to start_link and assert the result matches in init.

---

## WARN

### W-1 — `request_id` exposure paths
`lib/ad_butler/chat/server.ex:200-217,352-373`, `lib/ad_butler/chat/message.ex:32`

`request_id` is a server-minted v4 UUID with no PII, but it IS the join key into `llm_usage` cost rows. No current LiveView surfaces `assistant_msg.request_id`, but: (a) `config/config.exs:148` `:filter_parameters` doesn't include `"request_id"` — Phoenix param logs would leak it; (b) `chat/message.ex:32` doesn't carry `redact: true`, so `inspect/1` on the struct in any future Logger call will leak it. Fix now (cheap before W10): add `redact: true` on `request_id` in `Message` and `LLM.Usage`, and add `"request_id"` to `:filter_parameters`. Ensure W10 LV doesn't echo `assistant_msg.request_id` to the client — keep it as a server-side correlation key only.

### W-2 — Telemetry context cleanup verified
`lib/ad_butler/chat/server.ex:199-221`

No leak path. `try/after` at 210/218 fires on every return branch of `react_loop/3` (lines 197, 245, 255, 272). Recursion at line 267 overwrites the dict via `Process.put` (no nesting leak). `terminate/2` runs after the GenServer process exits, by which point the `after` clause has already fired. If `:brutal_kill` happens, the dict dies with the process. Verified safe. Recommend a regression test in `server_test.exs` asserting `Telemetry.get_context()` is `nil` after both success and `handle_stream_result/5` `{:error, _}` paths.

### W-3 — `chat_messages.request_id` not unique
`lib/ad_butler/llm.ex:72`, `lib/ad_butler/chat/message.ex`

`LLM.Usage` upserts on `conflict_target: [:request_id]`, but `chat_messages.request_id` has no unique index. A retried `persist_assistant/3` produces two messages with the same correlation key — future audit joins fan out silently. Add a partial unique index `WHERE request_id IS NOT NULL`, or document the 1:n cardinality.

### W-4 — `serialise_tool_call/1` fallback echoes `inspect/1` into jsonb
`lib/ad_butler/chat/server.ex:341-344`

Unreachable on the current LLM-driven path, but the fallback writes `%{"raw" => inspect(other)}` into `chat_messages.tool_calls`. CLAUDE.md bans `inspect/1` in log metadata for the same reason — and here it lands in persistent jsonb a tenant reads back via `list_messages/2`. Replace with `%{"error" => "unrecognised_tool_call_shape"}`.

---

## Clean / verified

- `tools/get_insights_series.ex:43-53` — explicit `metric_to_atom`/`window_to_atom` mappers cleanly close the atom-DoS surface.
- `chat/server.ex:322-329` `normalise_params/1` — keeps `String.to_existing_atom/1` for argument KEYS only (bounded by tool schemas), with `rescue ArgumentError -> args`. Acceptable.
- `tools/helpers.ex:30-37` `context_user/1` — rejects missing session_context explicitly, re-fetches user via `Accounts.get_user/1`. Clean.
- `chat.ex:329-334` `ensure_server/2` — auth before lazy-start verified.
- No SQL interpolation, no `raw/1`, no hardcoded secrets in changed files.

---

## Persistent

- W-1 / W-2 prior findings: mitigated by name, not enforcement → see H-1.
- W-3 race: confirmed not exploitable; Registry `{:already_started, pid}` is the atomicity guarantee.
- Prompt-injection wording: adequate for read-only W9. Re-audit at W11 — write-tool framing should explicitly forbid calling write tools with arguments derived from prior tool output without fresh user confirmation.

---

## Tools to run manually

- `mix sobelow --exit medium`
- `mix deps.audit` (no new deps in this cycle, but `req_llm` / `jido` advisories worth checking)
