# Review — Week 9 Review-Fix Changes

**Verdict**: REQUIRES CHANGES (2 HIGH defense-in-depth, 7 WARN, 5 SUGGESTION)
**Date**: 2026-05-01
**Reviewers**: elixir-reviewer, security-analyzer, testing-reviewer, iron-law-judge

Underlying reports:
- [elixir-review.md](elixir-review.md)
- [security-review.md](security-review.md)
- [test-review.md](test-review.md)
- [iron-law-review.md](iron-law-review.md)

Verification (run manually before this review): `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix credo --strict` (1 expected TODO), `mix check.tools_no_repo`, `mix check.unsafe_callers`, `mix test` (524/0/10 excluded), `mix test --include integration` (7 pre-existing RabbitMQ fails).

---

## BLOCKERS
None.

---

## HIGH (defense-in-depth — not exploitable today)

### H-1 — `unsafe_*` prefix is documentation, not enforcement
`lib/ad_butler/chat.ex:138-146,261-272` (security-review)

`mix check.unsafe_callers` exists in `mix.exs` but only forbids `Ads.unsafe_` outside `lib/ad_butler/chat/server.ex` allowlist. Extend the alias to also forbid `Chat.unsafe_` outside the allowlist before W11 broadens callers. Alternatives: move both fns into `AdButler.Chat.Internal`, or `@doc false`.

### H-2 — `Chat.Server.start_link/1` trusts its `session_id` arg
`lib/ad_butler/chat/server.ex:113-140` (security-review)

`init/1` calls `Chat.unsafe_get_session_user_id(session_id)` with whatever was passed to `start_link/1`. Today the only call site is the auth-gated `start_or_lookup_server/1`. A future helper / console / test setup that calls `Server.start_link(other_user_session_id)` directly hydrates that session's last 20 messages into state. Mitigate with `@doc false` on `start_link/1` and route everything through `ensure_server/2`.

---

## WARN

### IL-W1 — `Jason.encode!` inside GenServer turn execution can crash the call
`lib/ad_butler/chat/server.ex:347-349` (iron-law-judge)

`format_tool_results/1` raises if a tool returns a value `Jason` cannot encode. Replace with `Jason.encode/1` and a fallback string.

### W1 — Logger metadata keys `turn_id` / `conversation_id` not allowlisted
`config/config.exs:88-143` (elixir-review)

DB writes use these keys today, but the moment any `Logger.*` call references `turn_id:` or `conversation_id:`, formatter drops them silently. Add to allowlist now.

### W2 — `Helpers.decimal_to_float/1` has no fall-through clause
`lib/ad_butler/chat/tools/helpers.ex:45-48` (elixir-review)

Add `def decimal_to_float(_), do: nil` so an unexpected payload (binary, atom) returns nil instead of `FunctionClauseError` mid-stream.

### Sec W-1 — `request_id` exposure paths
`lib/ad_butler/chat/server.ex:200-217`, `lib/ad_butler/chat/message.ex:32` (security-review)

`request_id` is the join key into `llm_usage` (cost data). Add `redact: true` on `Message.request_id` and `LLM.Usage.request_id`; add `"request_id"` to `:filter_parameters`. Ensure W10 LV doesn't echo it to the client.

### Sec W-3 — `chat_messages.request_id` not unique
`lib/ad_butler/chat/message.ex` (security-review)

A retried `persist_assistant/3` produces two messages with the same `request_id`, fanning out future `llm_usage` joins. Add a partial unique index `WHERE request_id IS NOT NULL`, or document the 1:n relationship.

### Sec W-4 — `serialise_tool_call/1` fallback writes `inspect/1` into jsonb
`lib/ad_butler/chat/server.ex:341-344` (security-review)

Fallback path lands `%{"raw" => inspect(other)}` in persistent storage that the user reads back. Replace with `%{"error" => "unrecognised_tool_call_shape"}`.

### Test W — `insert_chat_message_at/4` precision contract not asserted
`test/support/factory.ex:127`, `lib/ad_butler/chat/message.ex:34` (testing-reviewer)

The schema declares `:utc_datetime_usec` and `inserted_at` is `cast`-able. Confirm the migration column type matches the schema declaration so sub-second offsets don't silently truncate. Mark resolved once verified.

---

## SUGGESTIONS

- **S1 (elixir)** — Add a one-line comment on `react_loop/3` documenting "each recursive invocation owns its own try/after pair" so future reviewers don't second-guess. (`server.ex:199-221`)
- **IL-S1** — Add an inline comment on `normalise_params/1`:25 explaining `to_existing_atom + rescue` is intentional (atom-DoS-safe via the rescue). (`server.ex:325`)
- **Test S1** — Hibernate test heap-size assertion is OTP-version sensitive; consider `Process.info(pid, :current_function) == {:erlang, :hibernate, 3}` as a more portable check. (`server_test.exs:157`)
- **Test S2** — Add a comment on the e2e `emit_token_usage_chunks` lambda: "fires in the Server process — context dict must be set before this call". Future move-to-Task would silently break the assertion chain. (`e2e_test.exs:115`)
- **Test S3** — Cross-reference `chat_test.exs:226` (list_messages contract test) to `server_test.exs:243` (cross-tenant `send_message` test) so the isolation chain is grep-able.

---

## PRE-EXISTING (outside this diff — flagged for follow-up)

- **IL-W2** — Workers still wrap metadata in `inspect/1` at: `token_refresh_worker.ex:84,92`, `fetch_ad_accounts_worker.ex:82,101`, `budget_leak_auditor_worker.ex:73,390,398`, `notifications.ex:39`. B3 fixed only `application.ex`. Worth a separate cleanup task.
- **IL-S2 / elixir S2** — `CompareCreatives.summary_row/1` is N+1 (4 series + 1 health = 5 queries × up to 5 ads = 25 round-trips). Already tracked by `# TODO(W11)`.
- **Server.normalise_params/1** — Mixed-key fallback (atom keys for known params, string keys for unknown) is a confusing shape; outside this diff, IL-S1 covers the comment-only fix.

---

## What's clean (verified)

- All 17 plan-defined fixes landed; verification commands green.
- Telemetry `try/after` cleanup verified across all return branches; no context leak between turns.
- Atom-DoS surface closed via `metric_to_atom/1` / `window_to_atom/1` mappers.
- Tenant isolation tests cover the public API surface (`get_session{,!}/2`, `list_sessions`, `ensure_server/2`, `send_message/3`).
- No SQL interpolation, no `raw/1`, no hardcoded secrets in changed files.

---

## Recommended next step

Both HIGHs (H-1, H-2) are defense-in-depth — neither is exploitable in the current codebase. Either:

- `/phx:triage` to cherry-pick which HIGH/WARN findings to fix now vs. defer to a W11 hygiene pass.
- `/phx:plan` to convert the HIGHs and Sec W-1/W-3/W-4 into a small follow-up plan (~1h).
- Fix the 2 HIGHs + 3 cheap WARNs (W1 allowlist, W2 fall-through, Sec W-4 string swap) directly — ~20 min total.
