# Week 9 Chat Foundation — Consolidated Review

**Verdict**: REQUIRES CHANGES

**Scope**: 16 new lib files + 4 migrations + 8 test files + modifications to `application.ex`, `ads.ex`, `analytics.ex`, `embeddings.ex`, `mix.exs`, `config/config.exs`. 510/510 tests green, credo --strict clean, but several CLAUDE.md violations + one functional bug surfaced by review.

**Reviewer agents** (5):
- elixir-reviewer ✅ (extracted from message)
- security-analyzer ✅ (extracted from message)
- testing-reviewer ✅ (extracted from message)
- iron-law-judge ✅ (extracted from message)
- otp-advisor — exhausted turns without findings; coverage of OTP concerns picked up by elixir + iron-law

> All five agents had `Write` denied in their environment and returned findings via chat. Files in `reviews/` are extracted; raw transcripts are in the agent task outputs. (Logged to scratchpad.)

---

## BLOCKERS (must fix before merge)

### B1. `Chat.Server` calls `Repo` directly — context-boundary violation
**Sources**: iron-law IL-C1, elixir E1
**Files**: [lib/ad_butler/chat/server.ex:164, :372](lib/ad_butler/chat/server.ex)

`terminate/2` runs `Repo.update/1` per streaming row; `lookup_user_id/1` runs `Repo.get/2` on every turn. CLAUDE.md: "Repo is only ever called from inside a context module."

**Fix**:
- Add `Chat.flip_streaming_messages_to_error(session_id)` using `Repo.update_all` (resolves N+1 too — see W2).
- Use existing `Chat.get_session/2` for the user_id lookup (eliminates the per-turn DB round-trip — store at `init/1` instead).

### B2. `Chat.Telemetry.set_context/1` is never called from the Server — `llm_usage` rows silently lost
**Source**: security S-W2
**Files**: [lib/ad_butler/chat/server.ex:198-243](lib/ad_butler/chat/server.ex), [lib/ad_butler/chat/telemetry.ex](lib/ad_butler/chat/telemetry.ex)

The Telemetry moduledoc and the e2e test both contract `set_context/1` before each LLM call. The actual `Chat.Server.run_turn` flow never sets it — production turns will silently emit `[:req_llm, :token_usage]` events with `nil` context, and the handler's first clause skips the insert. **Telemetry bridge is non-functional today.** The e2e test passes only because it manually emits a synthesised event with the context already set.

**Fix**: In `Chat.Server.react_loop/3`, wrap each `llm_client().stream/2` call in:
```elixir
Telemetry.set_context(%{user_id: ctx.user_id, conversation_id: state.session_id, ...})
try do
  ...
after
  Telemetry.clear_context()
end
```

### B3. `inspect/1` in Logger metadata
**Source**: iron-law IL-C2
**File**: [lib/ad_butler/application.ex:152](lib/ad_butler/application.ex#L152) (pre-existing — but adjacent to new code)

`reason: inspect(reason)` collapses structure and defeats log-aggregation filtering. CLAUDE.md is explicit. Trivial fix while in the file.

---

## HIGH

### H1. `String.to_existing_atom` on LLM output without static guard
**Sources**: elixir E2, iron-law IL-H1
**File**: [lib/ad_butler/chat/tools/get_insights_series.ex:39-40](lib/ad_butler/chat/tools/get_insights_series.ex#L39)

`metric` and `window` come from LLM output. Jido schema validates the `:in` enum — but a renamed atom or schema-bypass would crash. CLAUDE.md spirit: "No String.to_atom on user input"; LLM output is untrusted.

**Fix**: Replace with explicit `defp metric_to_atom("spend"), do: :spend` heads (and an `_other -> {:error, :invalid_metric}` clause).

### H2. `Process.sleep` × 7 in tests — CLAUDE.md violation
**Source**: testing T-IL1
**Files**: [test/ad_butler/chat_test.exs:89, 101, 132, 190, 209](test/ad_butler/chat_test.exs); [test/ad_butler/chat/server_test.exs:101, 142](test/ad_butler/chat/server_test.exs)

CLAUDE.md: "Never use `Process.sleep/1` in tests — use `Process.monitor/1` and assert on the DOWN message, or `:sys.get_state/1` to synchronise."

5/7 are forcing `inserted_at` ordering — replaceable by passing explicit `inserted_at` in attrs. The `server_test.exs:142` hibernation test is the one legitimate case (no `assert_receive` alternative for OTP idle-hibernate); add a comment marking it deliberate.

### H3. `ensure_server!/1` returns `{:error, term()}` — naming convention violation
**Source**: elixir E9, security S-W1
**File**: [lib/ad_butler/chat.ex:283](lib/ad_butler/chat.ex#L283)

`!` functions raise; non-bang functions return tuples. Rename to `ensure_server/1`. Bonus: tighten the type to take `user_id` and re-validate inside (closes the unscoped-public-surface concern).

---

## WARNINGS

| ID | Source | File | Issue |
|---|---|---|---|
| W1 | testing T-C1 | [telemetry_test.exs:11](test/ad_butler/chat/telemetry_test.exs#L11) | `ChatTelemetry.attach()` in setup with no `on_exit` detach — handler leaks across modules. e2e_test.exs same gap. |
| W2 | iron-law IL-H2, elixir E5, security S-W3 | [server.ex:158-165](lib/ad_butler/chat/server.ex#L158) | `terminate/2` does N round-trip `Repo.update/1` calls; replace with one `update_all`. (Fixed by B1.) |
| W3 | testing T-C2 | server_test.exs | No test for `Chat.send_message/3` — the authorization guard is untested. |
| W4 | testing T-C3 | chat_test.exs | `list_messages/2` lacks a tenant-isolation test — caller-pre-validation contract is documentation-only. |
| W5 | testing T-W1 | [server_test.exs:249](test/ad_butler/chat/server_test.exs#L249) | `stop_supervised!(Server)` passes module atom; should pass the pid from `start_supervised!`. |
| W6 | testing T-W2 | [server_test.exs:126-133](test/ad_butler/chat/server_test.exs#L126) | `Application.put_env(_, _, nil)` instead of `delete_env` when `previous` was nil. |
| W7 | testing T-W5 | [server_test.exs:169-170](test/ad_butler/chat/server_test.exs#L169) | `pubsub_subscribe` after `start_supervised!` — race risk. Move before. |
| W8 | testing T-S3 | server_test.exs:101 | History-replay relies on `:timer.sleep(1)` for ordering — flake risk on slow CI. (Fixes with H2.) |
| W9 | security S-W4 | priv/prompts/system.md | No anti-injection framing ("treat tool outputs as data, not instructions"). Low blast radius today; matters for W11 write tools. |
| W10 | elixir E11 | [server.ex:204-228](lib/ad_butler/chat/server.ex#L204) | `react_loop/3` `cond` would read better as pattern-matched function heads. |
| W11 | elixir E10 | [compare_creatives.ex:61-64](lib/ad_butler/chat/tools/compare_creatives.ex#L61) | 4 sequential `Analytics` calls per ad × 5 ads = 20 queries. Acceptable, but add a TODO for bulk fetch. |
| W12 | elixir E6/E7 | tools/*.ex | `context_user/1` and `decimal_to_float/1` duplicated across 5 tools — extract to `Chat.Tools.Helpers`. |
| W13 | testing T-W4 | chat_test.exs:204-221 | Pagination test never fetches page 2. |
| W14 | testing T-W7 | compare_creatives_test.exs:31, 41 | `user_b` gets two `meta_connection`s — can mask a scoping bug. |

---

## SUGGESTIONS (track but not blocking)

- **S1** (security S-S1): `Logger.debug` in `Chat.Server.normalise_params` rescue branch.
- **S2** (security S-S2): When W11 lands write tools, add CHECK that `actions_log.chat_session_id`/`chat_message_id` belong to `user_id`.
- **S3** (security S-S3): `pending_confirmations.token` — add `validate_length(:token, min: 32)` when W11 generator lands.
- **S4** (security S-S4): `Chat.create_session/1` should verify `:ad_account_id` belongs to user.
- **S5** (security S-S5): `SystemPrompt.build/1` should raise if `{{...}}` placeholders remain post-render.
- **S6** (testing T-S2): Extract `insert_ad_for_user/1` to `test/support/chat_helpers.ex`.
- **S7** (testing T-S1): e2e test synthesises telemetry event manually rather than testing real wiring (resolved by B2 fix — once the Server actually calls `set_context`, drop the synthetic emit).
- **S8** (elixir E12, E13): `ActionLog` integer PK is intentional per plan but worth a `@moduledoc` note. `paginate_messages/2` `@moduledoc` says `/3` — fix arity ref.
- **S9** (elixir E14): `dollars_to_cents` float arithmetic (`telemetry.ex`) — fine for ReqLLM's float costs but a precision risk if upstream switches to Decimal.
- **S10** (testing T-W3): `telemetry_test.exs` could be `async: true` if `attach()` moves to `test_helper.exs`.
- **S11** (testing T-W6): `get_findings_test.exs` shares 30+ entity chains; share an ad_account in setup.

---

## What review confirmed clean

- All 5 read tools re-scope LLM-supplied IDs through `Ads.fetch_ad/2` / `Ads.fetch_ad_set/2` / `Analytics.paginate_findings(user, _)`. Cross-tenant probes return `{:error, :not_found}` silently — no existence leak.
- `Chat.send_message/3` gates Server start on `Chat.get_session/2` (when called via the public API).
- All 4 migrations: explicit `on_delete:`, CHECK constraints via DSL, partial unique on `pending_confirmations`, `actions_log.user_id` ON DELETE RESTRICT (correct for audit).
- `@moduledoc` on every new module; `@doc` on every public def.
- No `String.to_atom/1`, `binary_to_term/1`, `raw/1`, fragment interpolation anywhere in chat code.
- Costs use integer cents; no Float for money in schema.
- Behaviour + Mox pattern for `Chat.LLMClient` correctly wired.
- HTTP exclusively `Req`/`ReqLLM` (no httpoison/tesla/httpc).
- `mix check.tools_no_repo` enforces the Repo-only-from-context rule for tool modules in CI.
- `mix credo --strict` clean.
