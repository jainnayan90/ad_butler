# Iron Law Audit — Week 9 Review-Fix Changes

## Summary
- Files scanned: 10 (chat.ex, server.ex, telemetry.ex, 5 tool files, application.ex, helpers.ex)
- Violations found: 4 (0 critical/blockers, 2 warnings, 2 suggestions)

**Prior-pass fixes confirmed:**
- B1 (Repo in Server/Telemetry) — CONFIRMED FIXED. Server delegates to `Chat.unsafe_*`; Telemetry delegates to `LLM.insert_usage`.
- B3 (inspect on Oban reason in application.ex) — CONFIRMED FIXED at line 154: `reason: reason` (raw term).
- H1 (String.to_existing_atom in get_insights_series) — CONFIRMED FIXED. Exhaustive `metric_to_atom/1` and `window_to_atom/1` guards replace dynamic conversion.
- H3 (! function returning tuple) — CONFIRMED FIXED. `ensure_server/2` returns `{:ok, pid} | {:error, term}`.

---

## High Violations (WARNING)

### IL-W1 [Iron Law #16] `Jason.encode!` inside GenServer turn execution — crash propagates to caller

- **File**: `lib/ad_butler/chat/server.ex:347-349`
- **Code**: `results |> Jason.encode!() |> String.slice(0, 4_000)` inside `format_tool_results/1`, called from `react_step/7`
- **Confidence**: LIKELY
- **Context**: This is NOT in a telemetry handler but the risk is the same pattern: a bang function inside a hot path that processes LLM-supplied data. If any tool returns a value `Jason` cannot encode (struct without `Jason.Encoder` impl, a PID, a `Decimal`), `Jason.encode!/1` raises and the `GenServer.call` exits to the caller. The `get_ad_health.ex:89` `Jason.encode!` in `truncate/2` has the same risk but is called inside a tool's `run/2`, not in server.ex directly.
- **Fix**: `case Jason.encode(results) do {:ok, json} -> String.slice(json, 0, 4_000); {:error, _} -> ~s({"error":"unencodable result"}) end`

### IL-W2 [Iron Law: inspect on Logger metadata] Pre-existing `inspect/1` on metadata persists in workers (B3 was partial fix) — PERSISTENT

- **Files**: `lib/ad_butler/workers/token_refresh_worker.ex:84,92`, `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:82,101`, `lib/ad_butler/workers/budget_leak_auditor_worker.ex:73,390,398`, `lib/ad_butler/notifications.ex:39`
- **Code**: `reason: inspect(reason)`, `errors: inspect(cs.errors)`, etc.
- **Confidence**: DEFINITE
- **Context**: CLAUDE.md rule is "Never wrap a metadata field in `inspect/1`." The B3 fix only addressed `application.ex`. These worker files were not touched in this PR but contain the same violation class.
- **Fix**: Pass raw terms: `reason: reason`, `errors: changeset.errors`. Ensure each key is allowlisted in `config/config.exs` Logger formatter.

---

## Medium Violations (SUGGESTION)

### IL-S1 [Iron Law: String.to_existing_atom on LLM keys] `normalise_params/1` converts LLM-supplied string keys to atoms

- **File**: `lib/ad_butler/chat/server.ex:325`
- **Code**: `{k, v} when is_binary(k) -> {String.to_existing_atom(k), v}`
- **Confidence**: REVIEW
- **Context**: `to_existing_atom` is safe from atom exhaustion (raises `ArgumentError` on unknown strings, caught at line 327). However, LLM-supplied keys that happen to collide with unrelated existing atoms (e.g. `:id`, `:node`) will pass through silently and could cause subtle mismatches. The rescue fallback returns the raw map.
- **Fix**: No immediate code change required — rescue guard makes this safe. Add an inline comment explaining why `to_existing_atom` is intentional.

### IL-S2 [CLAUDE.md: N+1 queries] `compare_creatives.ex` issues 5 Repo round-trips per ad inside `Enum.map`

- **File**: `lib/ad_butler/chat/tools/compare_creatives.ex:63-70`
- **Code**: `Enum.map(&summary_row/1)` where each call invokes `Analytics.get_insights_series` ×4 plus `Analytics.unsafe_get_latest_health_score` — up to 25 round-trips for 5 ads
- **Confidence**: REVIEW
- **Context**: A `TODO(W11)` comment acknowledges this. Not a correctness bug, but violates the N+1 queries = bugs principle for any non-trivial payload.
- **Fix**: Tracked by the TODO. Bulk-fetch health scores and series before the map in W11.

---

## Tenant Scoping — PASS

All `unsafe_*` surfaces in the changed files carry load-bearing `@doc` warnings. Tools re-scope through `Helpers.context_user/1` → `Ads.fetch_ad/2`. No unscoped public surface without `unsafe_` prefix found in the chat context.
