# Triage — week9-final-review

**Source**: [week9-final-review.md](week9-final-review.md)
**Date**: 2026-05-02
**Decision summary**: Fix 10 of 11 findings (B1+B2+B3, W1+W2+W3+W4, S1+S3+S4). Skip S2.

> **Note on scope**: This triage's largest item (W2) implements a new
> Analytics public API. Total fix size is closer to a small plan than a
> quick `/phx:work` cycle — recommend `/phx:plan` next.

---

## Fix Queue (10)

### BLOCKERs — all approved

- [ ] **B1 — Wire `SystemPrompt.build/1` into `Chat.Server.build_request_messages/2`**
  - **Files**: [lib/ad_butler/chat/server.ex:445-452](../../../lib/ad_butler/chat/server.ex#L445), `test/ad_butler/chat/server_test.exs`
  - **Action**: Prepend a `%{role: "system", content: SystemPrompt.build(...)}` message to the request list. Pass `today: Date.utc_today()`, `user_id: state.user_id`, `ad_account_id: nil` (multi-account session). Add a server test asserting the first stream call sees a system message containing the trust-boundary phrase.
  - **User decision**: fix inline now (rejected the "spin up W9D5 plan" alternative).

- [ ] **B2 — Replace `Jason.encode!` in `GetAdHealth.truncate/2` (Iron Law #5 auto-approved)**
  - **File**: [lib/ad_butler/chat/tools/get_ad_health.ex:89](../../../lib/ad_butler/chat/tools/get_ad_health.ex#L89)
  - **Action**: Apply the same `case Jason.encode/1` pattern used in `Chat.Server.format_tool_results/2`. Return `nil` on encode failure (matches the `truncate/2` `nil | String.t()` shape implied by callers).

- [ ] **B3 — Add `SimulateBudgetChange` test coverage (Iron Law #2 auto-approved)**
  - **File**: `test/ad_butler/chat/tools/simulate_budget_change_test.exs` (new)
  - **Action**: Minimum 4 tests:
    1. tenant isolation (user_b cannot project user_a's ad set)
    2. happy-path shape (returned map has expected keys)
    3. confidence band selection (`:low` / `:medium` / `:high`)
    4. zero-current-budget branch in `budget_ratio/2`

### Warnings — all approved

- [ ] **W1 — Document `actions_log` integer PK deviation**
  - **Files**: [lib/ad_butler/chat/action_log.ex](../../../lib/ad_butler/chat/action_log.ex), [priv/repo/migrations/20260501110606_create_actions_log.exs](../../../priv/repo/migrations/20260501110606_create_actions_log.exs)
  - **Action**: One-line comment in both files explaining: append-only audit log; integer serial PK preserves insert-order without per-row UUID overhead; intentional deviation from the project binary_id convention.
  - **User decision**: rejected the binary_id migration alternative.

- [ ] **W2 — Implement `Analytics.get_ads_delivery_summary_bulk/2` (replaces N+1 in CompareCreatives)**
  - **Files**: `lib/ad_butler/analytics.ex` (new public function), [lib/ad_butler/chat/tools/compare_creatives.ex:63-70](../../../lib/ad_butler/chat/tools/compare_creatives.ex#L63), `test/ad_butler/analytics_test.exs` (new tests for bulk fn)
  - **Action**: Design `Analytics.get_ads_delivery_summary_bulk(ad_ids, opts)` returning a map keyed by `ad_id` with `%{points: [...], summary: %{avg: ...}}`. Replace the 4 per-ad Analytics calls + the per-ad `unsafe_get_latest_health_score/1` with a single bulk call (or two — one for series, one for health). Add tenant-scope test (cross-tenant ad_ids return empty/scoped). Update the `# TODO(W11)` comment to remove or convert to a tracker reference.
  - **User decision**: rejected the "cap to 2 ads" quick-fix; wants the proper bulk API now.
  - **Scope warning**: this is the largest item in the triage — likely 1–2 hours.

- [ ] **W3 — Replace `normalise_params/1` silent rescue**
  - **File**: [lib/ad_butler/chat/server.ex:320-327](../../../lib/ad_butler/chat/server.ex#L320)
  - **Action**: On `String.to_existing_atom` `ArgumentError`, log a `Logger.warning` with the unknown string keys and return only the atom-keyed subset. Add a `:unknown_keys` entry to the Logger metadata allowlist in `config/config.exs` if it isn't already there.

- [ ] **W4 — Add PubSub assertions to e2e_test**
  - **File**: [test/ad_butler/chat/e2e_test.exs:99-185](../../../test/ad_butler/chat/e2e_test.exs#L99)
  - **Action**: `Phoenix.PubSub.subscribe(AdButler.PubSub, "chat:" <> session.id)` in setup; `assert_receive {:turn_complete, _, _}` after each turn invocation.

### Suggestions — selected subset

- [ ] **S1 — Add catch-all clauses to `CompareCreatives.sum_points/1` and `avg_value/1`**
  - **File**: [lib/ad_butler/chat/tools/compare_creatives.ex:84-86](../../../lib/ad_butler/chat/tools/compare_creatives.ex#L84)
  - **Action**: `defp sum_points(_), do: 0` and `defp avg_value(_), do: nil`. Prevents `FunctionClauseError` when Analytics returns an empty/nil shape.

- [ ] **S3 — Tighten e2e_test LLM stub argument assertions**
  - **File**: [test/ad_butler/chat/e2e_test.exs:113-137](../../../test/ad_butler/chat/e2e_test.exs#L113)
  - **Action**: In the second and third `expect(:stream, fn messages, _opts -> ...)`, assert that `messages` contains a `role: "tool"` entry from the prior turn. Catches regressions where tool results silently drop from history.

- [ ] **S4 — Document `telemetry_test.exs` `async: false`**
  - **File**: [test/ad_butler/chat/telemetry_test.exs:2](../../../test/ad_butler/chat/telemetry_test.exs#L2)
  - **Action**: One-line comment matching the server_test.exs pattern: named telemetry handler causes `:already_exists` under concurrent runs.

---

## Skipped (1)

- **S2** — `# TODO(W11)` issue tracker reference in `compare_creatives.ex:61`. **Reason**: Codebase has no issue tracker integration referenced anywhere else; adding `# TODO(W11-issue-N)` would be inventing a convention not used elsewhere. The TODO is also superseded by W2 (W2 actually implements the bulk fn the TODO referenced).

---

## Deferred (0)

(None — all reviewer-flagged items are either fixed or explicitly skipped.)
