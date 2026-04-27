# AdButler Project Health Audit
**Date**: 2026-04-27
**Branch**: week-01-Day-01-05-Data-Foundation-and-Ingestion
**Overall Grade**: C+ (77/100)

---

## Score Summary

| Category | Score | Grade |
|----------|-------|-------|
| Architecture | 79/100 | C+ |
| Performance | 79/100 | C+ |
| Security | 84/100 | B |
| Test Health | 62/100 | D |
| Dependencies | 82/100 | B |
| **Overall** | **77/100** | **C+** |

---

## Critical Issues (fix before next release)

### [SEC-1] `parse_page/1` crashes on non-integer URL param — 4 LiveViews
`lib/ad_butler_web/live/dashboard_live.ex:110`, `campaigns_live.ex:203`, `ad_sets_live.ex:208`, `ads_live.ex:199`

`String.to_integer(p)` raises `ArgumentError` on `?page=abc`. Sustained requests can exhaust LiveView supervisor restarts.

Fix all four:
```elixir
defp parse_page(nil), do: 1
defp parse_page(p) when is_binary(p) do
  case Integer.parse(p) do
    {n, _} -> max(1, n)
    :error -> 1
  end
end
```

### [TEST-1] `AdButler.LLM` context entirely untested
`lib/ad_butler/llm.ex` — no test file. `list_usage_for_user/2`, `total_cost_for_user/1`, `get_usage!/2` all untested. No tenant isolation test (CLAUDE.md non-negotiable).

### [TEST-2] `MatViewRefreshWorker` has no test file
All three `perform/1` clauses (7d, 30d, unknown-view fallback) are uncovered.

### [TEST-3] Paginate variants missing tests and tenant isolation
`paginate_ad_accounts/2`, `paginate_campaigns/2`, `paginate_ad_sets/2`, `paginate_ads/2` — no tests. The `list_*` counterparts have isolation tests; paginate variants do not. (CLAUDE.md non-negotiable.)

---

## High Priority Issues

### [ARCH-1] Workers call `Repo` directly — context boundary violation
- `lib/ad_butler/workers/sync_all_connections_worker.ex:23` — `Repo.transaction/2` directly
- `lib/ad_butler/workers/mat_view_refresh_worker.ex:12` — raw SQL on Repo
- `lib/ad_butler/workers/partition_manager_worker.ex:14` — DDL on Repo

Fix: expose context functions (`Accounts.stream_connections_and_run/1`, `AdButler.Analytics.refresh_view/1`, `AdButler.Partitions.create_future_partitions/0`) and call those instead.

### [ARCH-2] `HealthController` calls `Repo` in the web layer
`lib/ad_butler_web/controllers/health_controller.ex:12-13` — Ecto + Repo aliased directly in a controller.

### [ARCH-3] `ConnectionsLive` has 3 architecture violations in one file
`lib/ad_butler_web/live/connections_live.ex`
1. Plain list assign (not stream) for a collection rendered in a loop
2. No pagination (CLAUDE.md non-negotiable)
3. DB query runs on disconnected mount (no `connected?(socket)` guard)

### [ARCH-4] `AdButler.LLM.UsageHandler` bypasses context for writes
`lib/ad_butler/llm/usage_handler.ex:103-113` — calls `Repo.insert` directly. Should call `AdButler.LLM.insert_usage/1`.

### [PERF-1] All list/paginate queries fetch `raw_jsonb` unnecessarily
`lib/ad_butler/ads.ex` — no `select:` projection on paginate helpers. Each row returns the full Meta API JSON payload (~1-5 KB), never rendered in LiveViews. At 50 rows/page: ~100 KB of wasted Postgres → app transfer per page load.

Fix: add `select:` excluding `:raw_jsonb` (and `:targeting_jsonb`) in all list/paginate helpers.

### [PERF-2] `list_ad_accounts_internal/0` loads full table into memory
`lib/ad_butler/ads.ex:95-97`, called from both scheduler workers. No streaming, no limit. `SyncAllConnectionsWorker` correctly uses `Repo.stream`. Fix: `stream_active_ad_accounts/0` using `Repo.stream` + `Stream.chunk_every`.

### [SEC-2] PII exposure risk in auth_controller Logger call
`lib/ad_butler_web/controllers/auth_controller.ex:77`

```elixir
Logger.error("OAuth failure reason=#{inspect(reason)}")
```

`reason` can be an `Ecto.Changeset` containing `email` in its changes. Fix: `Logger.error("oauth_failure", reason: ErrorHelpers.safe_reason(reason))`.

---

## Medium Priority Issues

### [PERF-3] Double `list_meta_connection_ids_for_user` query on reconnect
`campaigns_live.ex:181-195`, `ads_live.ex:102-119`, `ad_sets_live.ex:101-119` — two sequential context calls each independently query `meta_connections WHERE user_id = ?`. Fix: resolve `mc_ids` once and pass to both calls.

### [PERF-4] `PartitionManagerWorker` runs identical pg_inherits query twice
`partition_manager_worker.ex:54-76` — `detach_old_partitions/0` and `check_future_partition_count/0` each issue the same catalog query. Extract `list_partition_names/0` and share the result.

### [PERF-5] Unbounded `list_ad_accounts/1` — filter dropdown
`lib/ad_butler/ads.ex:48-52` — no LIMIT. A user with hundreds of accounts loads all on every navigation. Cap at 200 or switch to server-filtered combobox.

### [ARCH-5] Scheduler workers default to single `Publisher`, not `PublisherPool`
`insights_scheduler_worker.ex:54-56`, `insights_conversion_worker.ex:53-55` — throughput bottleneck; inconsistent with `FetchAdAccountsWorker` which defaults to `PublisherPool`.

### [ARCH-6] `AdButler.Sync` is an undeclared context
No `Sync` context module, no declared public API, no `@moduledoc`. `MetadataPipeline` and `InsightsPipeline` are an implicit third domain boundary.

### [DEPS-1] `plug_attack ~> 0.4` is effectively unmaintained
Last published 2021. No CVE, but no security release path. Consider `hammer` + custom Plug or reverse-proxy rate limiting.

### [DEPS-2] `logger_json ~> 6.0` — one major behind
`config/prod.exs` uses `:backends` config form that will break on logger_json 7.x / Elixir Logger handler migration.

### [TEST-4] `Process.sleep` in integration test
`test/mix/tasks/replay_dlq_test.exs:186` — gated behind `@moduletag :integration` but still a rule violation.

### [TEST-5] Mox `stub` where `expect` should be — 2 files
`test/ad_butler/accounts_authenticate_via_meta_test.exs:31,39-43`, `lib/ad_butler_web/controllers/auth_controller_test.exs:64` — silent no-call scenarios would pass.

---

## Low Priority / Informational

- **[SEC-3]** Dev Cloak key defaults to all-zeros base64 in `dev.exs`. Remove default, raise if unset.
- **[DEPS-3]** `req ~> 0.5` blocks 0.6.x/1.x — widen to `~> 0.5 or ~> 1.0`.
- **[TEST-6]** Ordering test flakiness risk — `accounts_test.exs:317` uses `||` fallback that's always true when rows share same timestamp second.
- **[TEST-7]** `sync_all_connections_worker_test.exs` unnecessary `async: false`.
- **[TEST-8]** Pre-existing `AccountsTest` email-nil failure has no `@tag :skip` or issue reference.
- **[ARCH-7]** `dev_routes` guard should be tightened to `config_env() == :dev` check.

---

## Cross-Cutting Correlations

- **ConnectionsLive** appears in both Architecture (3 violations) and Performance (unbounded list, no stream). Single file fix closes 5 findings.
- **LLM context** appears in both Architecture (Repo bypass) and Test Health (untested). One focused sprint closes both.
- **Workers calling Repo directly** (ARCH-1) is the most widespread architectural pattern to fix — affects 3 workers.

---

## Confirmed Healthy

- Tenant scoping: `scope/2` / `scope_ad_account/2` on all user-facing queries
- Broadway pipeline batching: pre-fetches all connections in one `WHERE IN` before processing
- Bulk upserts: `Repo.insert_all` with `on_conflict` used throughout
- Index coverage: all FKs indexed, composite indexes on query paths, partial index on `token_expires_at`
- External service wrapping: Behaviour + Mox pattern correct throughout
- OAuth security: `secure_compare`, 600s TTL, CSRF, CSP, `http_only`/`secure` cookie flags
- Token encryption: Cloak AES-GCM-256, `redact: true`, `filter_parameters` covers all secrets
- No `String.to_atom/1` on user input anywhere
- All periodic work via Oban — no GenServer timer loops
- HTTP client consistency: Req only, no HTTPoison/Tesla
- No version conflicts in mix.lock
- Core stack (Phoenix 1.8, LiveView 1.1, Oban 2.21) at or near latest

---

## Action Plan

### Immediate (before next PR)
1. Fix `parse_page/1` in all 4 LiveViews — security crash risk
2. Fix `auth_controller.ex:77` Logger call — PII risk

### Short-term (next sprint)
3. Add tests for `AdButler.LLM` context + tenant isolation
4. Add tests for `MatViewRefreshWorker`
5. Add tests + isolation for all `paginate_*` functions
6. Fix `ConnectionsLive` — stream, pagination, disconnected guard
7. Add `select:` projection to list/paginate queries — biggest perf win
8. Move `Repo` calls in workers behind context functions (ARCH-1)

### Long-term (quarterly)
9. Replace `plug_attack` with actively maintained alternative
10. Upgrade `logger_json` to 7.x
11. Formalize `AdButler.Sync` as a proper context
12. Move `list_ad_accounts_internal` to `Repo.stream`
