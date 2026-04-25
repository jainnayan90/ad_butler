# Review: health-audit-findings-apr23

**Date:** 2026-04-23
**Branch:** module_documentation_and_audit_fixes
**Files changed:** 13 source + test files
**Verdict: REQUIRES CHANGES** — 1 Critical, 4 Warnings, 9 Suggestions

---

## CRITICAL

### C1 — `token_refresh_sweep_worker.ex:51` — `{:error, :all_enqueues_failed}` fires in healthy steady state

**Source:** oban-specialist

`Oban.insert_all` uses `on_conflict: :nothing` at the DB level. Conflict-skipped rows are **not returned** — they silently disappear from the result list. Current counting logic:

```elixir
succeeded = length(inserted_jobs)   # only newly-inserted rows
failed = total - succeeded          # includes conflict-skipped rows
```

In normal steady-state — where `TokenRefreshWorker` jobs already exist for all expiring connections — `insert_all` returns `[]`, `succeeded == 0 and total > 0`, and the sweep returns `{:error, :all_enqueues_failed}`. Oban retries 3×, logs spurious errors, then discards the job — **every 6 hours, permanently**.

**Fix:** Remove the `{:error, :all_enqueues_failed}` branch entirely. `Oban.insert_all` raises on a real DB error rather than returning an error tuple, so `succeeded == 0` is not a reliable failure signal. Return `:ok` always and log `newly_enqueued` vs `skipped` at `:info`.

---

## Warnings

### W1 — `token_refresh_sweep_worker.ex:37` — `length/1` on linked list is O(n)

**Source:** elixir-reviewer

```elixir
if length(connections) == @default_limit do
```

Traverses the full list. Fix: fetch `@default_limit + 1` rows, check `length(connections) > @default_limit`, take back to limit — one pass instead of two. Or use a separate `Repo.aggregate(:count)` guard.

### W2 — `token_refresh_sweep_worker.ex:51` — MapSet lookup fragile across mock boundary

**Source:** elixir-reviewer

```elixir
inserted_ids = MapSet.new(inserted_jobs, & &1.args["meta_connection_id"])
```

After a real DB round-trip, `Oban.Job` args are string-keyed. A mock returning atom-keyed maps makes every lookup `nil`, silently corrupting `failed_ids`. The test short-circuits via empty list so the gap is never exercised.

**Fix:** `job.args["meta_connection_id"] || job.args[:meta_connection_id]`

### W3 — `plug_attack_test.exs:87` — modulo-250 octet pool can collide across runs

**Source:** testing-reviewer

`rem(System.unique_integer([:positive]), 250) + 1` yields values 1–250. On `--repeat-until-failure` or if a prior run aborted without flushing ETS, a reused octet pushes an IP over threshold before the test fires its 3 allowed requests.

**Fix:** Flush the PlugAttack ETS bucket in a `setup` block, or call `:ets.delete_all_objects/1` on the table — removing the need for unique IPs in those tests entirely.

### W4 — `token_refresh_sweep_worker_test.exs:74` — `Application.put_env` mid-test risks leaked state on crash

**Source:** testing-reviewer

`put_env` is set in the test body with an inline `on_exit` for cleanup. If the test raises before registering `on_exit`, cleanup never runs and `:oban_mod` remains set for subsequent tests.

**Fix:** Move both `put_env` and `on_exit` into a named setup function scoped to the describe block so cleanup is always registered.

---

## Suggestions

### S1 — `token_refresh_sweep_worker.ex` — Log `total`/`newly_enqueued`/`skipped` at `:info` on every run
(oban-specialist — makes sweep health observable without requiring errors to appear)

### S2 — `token_refresh_sweep_worker_test.exs:19` — Test comment says "15 days" but `@sweep_days_ahead` is 14
(oban-specialist — fix the off-by-one in the comment)

### S3 — `ads.ex:298` — `bulk_upsert_ads/2` is `@doc false` but is called from `MetadataPipeline`
(elixir-reviewer — it's a real cross-context public API; replace `@doc false` with a proper `@doc`)

### S4 — `application.ex` — `require Logger` inside private functions is redundant
(elixir-reviewer — one top-level `require Logger` is idiomatic)

### S5 — `plug_attack.ex` — `if` returning `nil` is semantically implicit; add a one-line comment
(elixir-reviewer — PlugAttack treats `nil` as "rule did not fire"; make this intentional, not surprising)

### S6 — `accounts_test.exs:294` — `stream_active_meta_connections` negative assertion too weak
(testing-reviewer — `refute Enum.any?` passes even if the filter is broken; use `assert Enum.all?(&1.status == "active")`)

### S7 — `metadata_pipeline_test.exs:233` — `list_ads :rate_limit_exceeded` missing DB write assertion
(testing-reviewer — the `list_campaigns` rate-limit test guards with `Repo.aggregate(...count) == 0`; add the same for `Ad`)

### S8 — `auth_controller_test.exs:127` — token upsert assertion is negative only
(testing-reviewer — `assert connection.access_token != "old_token"` would pass if set to any value; assert `"new_token_after_upsert"` directly)

### S9 — Security: `batch_request/2` keeping token in POST body is correct but needs an explanatory comment
(security-analyzer — otherwise a future reviewer will "fix" it by moving to Bearer, which Meta Batch API does not accept)

---

## Pre-existing / Not in Diff (not actioned)

- Iron Law HIGH: `TokenRefreshWorker` child-level uniqueness — **confirmed not a violation**: `TokenRefreshWorker` already declares `unique: [period: {23, :hours}, keys: [:meta_connection_id]]` (verified by oban-specialist).
- Iron Law MEDIUM: Raw `mc_ids` overloads lack enforced caller trust boundary — SUGGESTION only; values are correctly pinned with `^`, no injection risk today.
- Security L2: `auth_header/1` CRLF guard — optional defence-in-depth; not reachable in practice (tokens from Meta OAuth / DB).

---

## Security posture (net change)

**Improved.** SEC-1 removes token-in-URL across 6 functions. SEC-2 tightens rate limit. No new attack surface introduced. `oban_mod()` seam is test-only and not user-reachable.
