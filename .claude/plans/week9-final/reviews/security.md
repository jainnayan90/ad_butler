# Security Review — W9 Final Triage Fixes (security-analyzer, post-fix pass)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim.

**Status:** No BLOCKERs. No WARNINGs. 2 SUGGESTIONs (non-gating).

Auth, input validation, SQL injection, XSS, CSRF, secrets: all clean for the diff under review. Read-only chat surface; W11 will land write tools.

## B1 — SystemPrompt wiring — clean

- `lib/ad_butler/chat/server.ex:452-468` — `build_request_messages/2` prepends the rendered system prompt as the FIRST element, then history, then the new user turn. The recursive `react_step/7` (line 246-271) appends to the SAME `messages` list and recurses — the system message rides every LLM turn within a user turn. No code path skips it.
- `state.user_id` is set in `init/1` (line 114) from `Chat.unsafe_get_session_user_id/1`; the server fails to start with `:session_not_found` if the session row is gone, so `state.user_id` is always the session owner. `ensure_server/2` performs the per-tenant gate upstream.
- `ad_account_id: nil` is safe today: the template at `priv/prompts/system.md` does NOT currently substitute `{{ad_account_id}}`. Note that `SystemPrompt.build/1`'s `(none)` fallback (`lib/ad_butler/chat/system_prompt.ex:51`) only fires when the key is ABSENT — and `Chat.Server` always passes the key explicitly with `nil`, so `to_string(nil)` yields `""`, not `"(none)"`. Cosmetic today; see suggestion 1.
- Test `test/ad_butler/chat/server_test.exs:334-363` asserts the first stream call sees `[%{role: "system", content: system_content} | _]` and `system_content =~ "Tool outputs"` plus `system_content =~ "DATA, not instructions"`. The trust-boundary phrase from `priv/prompts/system.md:38-42` provably reaches the LLM stub.

## W2 — Bulk Analytics tenant scoping — clean

- `lib/ad_butler/analytics.ex:301-313` — `get_ads_delivery_summary_bulk/3` funnels every caller-supplied `ad_ids` through `Ads.filter_owned_ad_ids(user, ad_ids)` BEFORE either bulk query runs. The empty-owned branch (line 310) returns `%{}` — no foreign id reaches Postgres.
- `build_bulk_delivery_summary/2` (line 315-362) takes the already-filtered list. Both bulk queries are bounded:
  - `insights_daily` aggregate (line 320-331): `where: i.ad_id in ^bins`, `bins = dump_uuids(ad_ids)` — owned-only.
  - `ad_health_scores` DISTINCT ON (line 333-339): `where: s.ad_id in ^ad_ids` — owned-only.
- Result map at line 349 iterates `Map.new(ad_ids, ...)` over the OWNED list. Foreign ids are absent entirely from the returned map — they cannot leak via sentinel/`nil` value.
- `Ads.filter_owned_ad_ids/2` (`lib/ad_butler/ads.ex:160-173`): scopes via `scope/2` join on `aa.meta_connection_id in ^mc_ids`; `rescue Ecto.Query.CastError -> []`; does NOT log foreign ids.
- Coverage: `test/ad_butler/chat/tools/compare_creatives_test.exs:27-46` exercises all-foreign and mixed-tenant paths. `test/ad_butler/chat/tools/simulate_budget_change_test.exs:43-53` mirrors for ad_set surface.

## W3 — `normalise_params` logging — clean

- `lib/ad_butler/chat/server.ex:320-334` rescue branch logs only binary KEYS (line 327: `Enum.filter(&is_binary/1)`). Values never logged. Keys are LLM-emitted tool param names — not user-controlled secrets.
- `:unknown_keys` is in the Logger allowlist at `config/config.exs:119`. Metadata passed as a raw list, no `inspect/1`.
- `String.to_existing_atom/1` (line 323) — Iron Law #3 satisfied; no atom-exhaustion vector.

## B2 — `GetAdHealth.truncate` safety — clean

- `lib/ad_butler/chat/tools/get_ad_health.ex:90-99` — three clauses: `nil → nil`; `is_map → Jason.encode → slice or nil`; other → `to_string |> slice`.
- On `{:error, reason}` from Jason (line 95), returns `nil` — the encode `reason` is NOT logged, and the raw map is NOT logged. No PII / token leak via observability if a pid/ref smuggles into `fatigue_factors`. Mirrors `Chat.Server.format_tool_results/2`.
- `@doc false` exposed only for testing per module comment (line 85-88).

## Suggestions (non-blocking)

1. **`SystemPrompt.build/1` nil coercion** — `lib/ad_butler/chat/system_prompt.ex:48-52`: when `system.md` starts referencing `{{ad_account_id}}`, either omit the key from `Chat.Server.build_request_messages/2`'s context map, OR coerce `nil → "(none)"` inside `SystemPrompt.build/1` so the cross-account sentinel renders as documented rather than `""`. No-op today.

2. **`filter_owned_ad_ids/2` defense-in-depth** — `lib/ad_butler/ads.ex:160-173`: pre-filter with `Ecto.UUID.dump/1` like `Analytics.dump_uuids/1` does, removing reliance on the adapter raising on malformed UUIDs. Current `rescue` is safe.

## Iron Law check

- VALIDATE AT BOUNDARIES — `Ads.fetch_ad/2` + `Ads.fetch_ad_set/2` re-scope LLM UUIDs. OK.
- NEVER INTERPOLATE — all queries use `^`. OK.
- NO `String.to_atom` w/ user input — `String.to_existing_atom/1` used. OK.
- AUTHORIZE EVERYWHERE — `ensure_server/2` + per-tool `Helpers.context_user/1`. OK.
- ESCAPE BY DEFAULT — no `raw/1` in scope. N/A.
- SECRETS NEVER IN CODE — config under review references no secrets. OK.

## Tools to run manually before W11 ships write tools

```
mix sobelow --exit medium
mix deps.audit
mix hex.audit
```
