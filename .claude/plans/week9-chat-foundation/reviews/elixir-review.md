⚠️ EXTRACTED FROM AGENT MESSAGE (agent had no Write tool access; see scratchpad)

# Code Review: Week 9 Chat Foundation — Elixir Idioms

**Status**: Changes Requested — 5 critical, 6 warnings, 3 suggestions

---

## Critical Issues

**E1. `Chat.Server` calls `Repo` directly — violates context boundary** (`server.ex:164, 372`)

`terminate/2` calls `AdButler.Repo.update/1` and `lookup_user_id/1` calls `AdButler.Repo.get/2`. Both bypass the `Chat` context. CLAUDE.md is explicit: "This module is the only place outside an Ecto migration that calls Repo for chat tables." Add `Chat.flip_streaming_messages_to_error/1` and `Chat.get_session_user_id/1` to the context module.

**E2. `String.to_existing_atom` on LLM-supplied strings** (`tools/get_insights_series.ex:39-40`)

`String.to_existing_atom(metric)` and `String.to_existing_atom(window)` on LLM output can raise `ArgumentError` if the atom isn't loaded. Use a static lookup map keyed on the valid strings instead.

**E3. `normalise_params/1` silently falls back to string keys on atom error** (`server.ex:292-298`)

`rescue ArgumentError -> args` returns the original string-keyed map, which tool modules don't handle (they pattern-match on atom keys). The error is swallowed with no log. Either surface the error or filter against known atoms explicitly.

**E4. Per-turn redundant DB query: `lookup_user_id/1`** (`server.ex:371-375`)

Fires a `Repo.get` on every turn. `user_id` is already available at `init/1` time from the session; store it in `Server` state and eliminate the per-turn query.

**E5. `terminate/2` loads ALL messages to find streaming rows** (`server.ex:157-164`)

`Chat.list_messages(session_id)` with no limit is O(n) in `terminate/2`. Replace with a targeted `Repo.update_all` in the context: `from(m in Message, where: ... and m.status == "streaming") |> Repo.update_all(set: [status: "error"])`.

---

## Warnings

**E6. `context_user/1` duplicated across all 5 tool modules** — Extract to `AdButler.Chat.Tools.Context.resolve_user/1`.

**E7. `decimal_to_float/1` duplicated in `GetAdHealth` and `CompareCreatives`** — Move to shared helper.

**E8. `application.ex:152` wraps `reason` in `inspect/1`** — Violates CLAUDE.md logging rule; pass the raw term. (Pre-existing, in the Oban event handler — flagged here because it sits next to new code.)

**E9. `ensure_server!/1` returns `{:error, term()}` — naming convention violation** (`chat.ex:283`) — `!` functions must raise, not return error tuples. Rename to `ensure_server/1`.

**E10. `CompareCreatives.summary_row/1` makes 4 sequential `Analytics` calls per ad** (`compare_creatives.ex:61-64`) — Up to 25 queries for 5 ads. Document the known ceiling or add a TODO for bulk fetch.

**E11. `react_loop/3` uses `cond` where pattern-matched function heads would be clearer** (`server.ex:204-228`).

---

## Suggestions

**E12. `ActionLog` uses integer primary key** (`action_log.ex:17`) — inconsistent with all other new schemas; document the deliberate choice if intentional. (Plan specifies `bigserial` so this is intentional — but worth a `@moduledoc` note.)

**E13. `paginate_messages` arity mismatch: `@moduledoc` says `/3` but function is `/2`** (`chat.ex:172`).

**E14. `dollars_to_cents` uses float arithmetic on cost values** (`telemetry.ex:177`) — `trunc(Float.round(usd * 100, 0))` is unreliable for money; use `Decimal` if the upstream measurement is decimal-typed. (ReqLLM emits floats per W9D0 spike — fine for now, but a precision risk to track.)
