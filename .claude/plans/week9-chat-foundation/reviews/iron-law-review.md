⚠️ EXTRACTED FROM AGENT MESSAGE

# Iron Law Violations — Week 9 Chat Foundation

**Files scanned**: 18 (all new lib/chat modules, 4 migrations, application.ex)
**Violations found**: 4 (2 critical, 2 high)

---

## Critical Violations

### [BLOCKER] IL-C1: Repo Called Directly Inside Chat.Server — Not a Context Module

**File**: `lib/ad_butler/chat/server.ex:164` and `:372`

- Line 164 (`terminate/2`): `|> AdButler.Repo.update()` — iterates streaming messages and updates each one directly.
- Line 372 (`lookup_user_id/1`): `AdButler.Repo.get(AdButler.Chat.Session, session_id)` — raw schema read from inside the GenServer.

CLAUDE.md is unambiguous: "Repo is only ever called from inside a context module." `Chat.Server` is an OTP process, not a context. Both calls bypass the tenant-scoping contract.

**Fix**: Add `Chat.flip_streaming_messages_to_error(session_id)` to the `Chat` context (using `Repo.update_all` for the batch update). For `lookup_user_id`, use the existing `Chat.get_session/2` — already returns `{:ok, %Session{user_id: uid}}`.

---

### [BLOCKER] IL-C2: inspect/1 in Logger Metadata — application.ex Oban Handler

**File**: `lib/ad_butler/application.ex:152`

```elixir
reason: inspect(reason),
```

CLAUDE.md: "Never wrap a metadata field in `inspect/1`." Pre-existing in the Oban exception handler — adjacent to new code, worth fixing while in the file.

**Fix**: `reason: reason` — pass the raw term directly.

---

## High Violations

### [HIGH] IL-H1: String.to_existing_atom on LLM-Supplied Values Without Fallback Guard

**File**: `lib/ad_butler/chat/tools/get_insights_series.ex:39-40`

```elixir
String.to_existing_atom(metric),
String.to_existing_atom(window)
```

`metric` and `window` originate from LLM output, validated only by the Jido schema `:in` enum. If schema validation is bypassed or the atom doesn't exist in the VM, raises and crashes the tool call.

**Fix**: Use a `defp` mapping with explicit pattern match heads for the allowed values, returning `{:error, :invalid_metric}` for anything outside the set.

---

### [HIGH] IL-H2: N+1 Repo.update Loop in terminate/2 (sub-issue of IL-C1)

**File**: `lib/ad_butler/chat/server.ex:158-165`

`Enum.each` issues one `Repo.update/1` per streaming message. In practice a single turn has at most one streaming message, but no structural guard.

**Fix**: Replace with a single `Repo.update_all(...)` — encapsulated in a `Chat` context function (resolves IL-C1 too).

---

## Passing (no violations)

- `@moduledoc` on all 10 new modules; `@doc` on all public `def`.
- No `:float` for money — costs use `:integer` cents throughout.
- No `String.to_atom/1` anywhere in `lib/ad_butler/chat/` — only `to_existing_atom`.
- All 4 migrations use `create constraint(...)` (not raw `execute`) for CHECKs; reversible via `def change`.
- HTTP: only `Req`/`ReqLLM` used.
- LLM client follows behaviour + Mox pattern correctly.
- Logger metadata keys present in the `config/config.exs` allowlist.
- `@external_resource` correctly declared in `Chat.SystemPrompt`.
- All 5 tools call only context modules — never `Repo` directly.
- `Chat.Server` is stateful coordination (not a timer-loop job) — GenServer use is justified.
- `DynamicSupervisor` + `Registry` supervision tree correct.
- Test files exist for all major modules.
- `Jason.encode!` only in data-formatting helpers, not telemetry handlers.
- `Chat.Telemetry.handle_event` uses safe pattern.
