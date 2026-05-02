# Security Audit: week9-followup-fixes (security-analyzer)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — agent reported Write tool denied; orchestrator captured chat output verbatim. See `scratchpad.md` 2026-05-02 entry.

**Verdict: PASS — no BLOCKER, no WARNING.** 2 SUGGESTIONs and 2 NITs on new code.

## Verification of Prior-Review Concerns

**Path-anchored grep gate (was BLOCKER previously) — FIXED.**
`scripts/check_chat_unsafe.sh` runs `grep -rn 'Chat\.unsafe_' lib --include='*.ex'` from project root, then filters with `^lib/ad_butler/chat/server.ex:` and `^lib/ad_butler/chat.ex:`. Because `grep -rn` produces paths anchored with the search root, the `^lib/...` patterns only match those exact files. A future `lib/foo/server.ex` or `lib/bar/chat.ex` cannot slip through — the basename-`--exclude` flaw is genuinely closed. Test files (`test/...`) are correctly excluded since the script searches `lib` only. Confirmed callsites: `lib/ad_butler/chat/server.ex:114, 169`.

**`kind_of/1` vs `inspect(other)` (D-FU-02) — SOUND.**
`serialise_tool_call/2` writes `%{"error" => "unrecognised_tool_call_shape"}` to jsonb (term contents never reach DB). Logger metadata only carries `kind: kind_of(other)` ∈ {`"map"`, struct module name, atom name, `"other"`}. No user-typed text leaks. Clause ordering is correct: `is_struct/1` precedes `is_map/1` so structs don't fall through to `"map"`.

**`Jason.encode!` removed (IL-W1) — SOUND.**
`format_tool_results/2` uses `Jason.encode/1` with safe fallback. `String.slice(json, 0, 4_000)` post-encode is safe (operates on already-valid JSON).

**`redact: true` coverage — COMPLETE on schemas.**
Confirmed `lib/ad_butler/chat/message.ex:32` and `lib/ad_butler/llm/usage.ex:38`. `:filter_parameters` includes `"request_id"`. Logger formatter allowlist adds `:turn_id`, `:conversation_id` (UUIDs — safe to log).

**Partial unique index — NOT enumeration-exploitable.**
`request_id` is a server-minted UUID never exposed to clients (now also redacted). `append_message/1` raises `Ecto.ConstraintError` on collision — not a distinguishable response. The `WHERE request_id IS NOT NULL` predicate correctly leaves user-message rows (no request_id) free to coexist.

## Findings on the New Diff

### SUGGESTION-1 — `format_tool_results/2` is `def` with `@doc false`
**Location**: `lib/ad_butler/chat/server.ex:356-375`
The "public for unit testing only" comment leaves it reachable from any module. Pure function so risk is low, but stylistically a `defp` tested through `react_step/7` would tighten the API surface. Acceptable as-is.

### SUGGESTION-2 — Telemetry context map redaction (matches deferred item)
**Location**: `lib/ad_butler/chat/telemetry.ex:25, 174`
`Process.put(@context_key, %{request_id: ...})` stores `request_id` in a plain map. No code path today interpolates the full map into Logger metadata or messages, so no current leak. The risk surface is future code: any `Logger.metadata(chat_context: ctx)` or `inspect(ctx)` in a log message would expose `request_id`. **No new evidence the deferral is unsafe** — re-flag in W10/W11 if a LiveView surfaces the context. Fix when picked up: wrap in a struct with `@derive {Inspect, except: [:request_id]}`.

### NIT-1 — `serialise_tool_call/2` warning carries no `turn_id`/`request_id`
**Location**: `lib/ad_butler/chat/server.ex:343-346`
Operator gets `session_id` and `kind` but cannot correlate the warning back to the assistant turn. Threading `turn_id` from `ctx` would make the log actionable. Observability only.

### NIT-2 — `decimal_to_float/1` fall-through silently masks type errors
**Location**: `lib/ad_butler/chat/tools/helpers.ex:48`
Safe (no crash, no leak) but a `%Date{}` accidentally passed in now silently becomes `nil`. Not a security issue.

## Posture Delta

Authentication, XSS, CSRF, SQL injection, tenant scope: unchanged and clean. Input validation and logging robustness improved (no-raise paths in `format_tool_results/2` and `decimal_to_float/_`). Authorization boundary (`Chat.unsafe_*`) now has sound CI enforcement. Secrets handling on `request_id` complete at the schema/Phoenix layer; one known gap (Telemetry context map) explicitly deferred.

## Manual Tools to Recommend

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
- `mix check.unsafe_callers` (already in `precommit`)
