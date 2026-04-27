# Audit Triage — 2026-04-27
Source: `.claude/audit/summaries/project-health-2026-04-27.md`

## Fix Queue (20 items)

### Iron Law Violations (auto-approved)

- [ ] SEC-1 — Fix `parse_page/1` in 4 LiveViews (dashboard, campaigns, ad_sets, ads) — `Integer.parse` with fallback to 1
- [ ] SEC-2 — Fix `auth_controller.ex:77` Logger string interpolation → `Logger.error("oauth_failure", reason: ErrorHelpers.safe_reason(reason))`
- [ ] ARCH-1 — Move `Repo` calls out of 3 workers into context functions
  - `SyncAllConnectionsWorker` → `Accounts.stream_connections_and_run/1`
  - `MatViewRefreshWorker` → `Analytics.refresh_view/1` (new context)
  - `PartitionManagerWorker` → `Analytics.create_future_partitions/0` + `Analytics.detach_old_partitions/0`
- [ ] ARCH-2 — Move `Repo` out of `HealthController` → `AdButler.Health.db_ping/0`
- [ ] ARCH-3 — Fix `ConnectionsLive`:
  - Convert plain list assign to stream
  - Add pagination (`paginate_meta_connections/2` context function)
  - Gate DB query behind `connected?(socket)`
- [ ] ARCH-4 — `LLM.UsageHandler` → call `AdButler.LLM.insert_usage/1` instead of `Repo.insert` directly
- [ ] TEST-1 — Add test file for `AdButler.LLM` context with tenant isolation (two-user cross-tenant test for each scoped function)
- [ ] TEST-3 — Add tests + isolation for all 4 `paginate_*` functions in Ads context

### High Priority (user-selected)

- [ ] PERF-1 — Add `select:` projection to all `list_*` and `paginate_*` in `ads.ex` excluding `:raw_jsonb` (and `:targeting_jsonb` for ad sets)
- [ ] PERF-2 — Implement `stream_active_ad_accounts/0` using `Repo.stream` + `Stream.chunk_every`; update both scheduler workers
- [ ] TEST-2 — Add test file for `MatViewRefreshWorker` covering 7d, 30d, and unknown-view fallback clauses

### Medium Priority (user-selected)

- [ ] PERF-3 — Resolve `mc_ids` once in `handle_info(:reload_on_reconnect)` in campaigns_live, ads_live, ad_sets_live
- [ ] PERF-4 — Extract `list_partition_names/0` in `PartitionManagerWorker` and share between `detach_old_partitions/0` and `check_future_partition_count/0`
- [ ] PERF-5 — Add `limit: 200` to `list_ad_accounts/1` in `ads.ex`
- [ ] TEST-4 — Fix `Process.sleep(20)` in `replay_dlq_test.exs:186` → use `assert_receive` or poll via `:sys.get_state`

### Low Priority (user-selected)

- [ ] ARCH-5 — Change scheduler workers default from `Publisher` to `PublisherPool`
- [ ] TEST-5 — Replace `stub` with `expect(..., 1, fn ...)` in `accounts_authenticate_via_meta_test.exs` and `auth_controller_test.exs`
- [ ] SEC-3 — Remove default all-zeros Cloak key from `dev.exs`; raise if `CLOAK_KEY_DEV` unset
- [ ] DEPS-2 — Upgrade `logger_json` to `~> 7.0`; update `:backends` config to new handler form

## Skipped

- ARCH-6 — AdButler.Sync undeclared context (longer refactor, tracked for future sprint)
- DEPS-1 — plug_attack unmaintained (no CVE; replacement is a larger decision)
- DEPS-3 — req ~> 0.5 constraint (minor; widen when upgrading)
- TEST-6 — Ordering test flakiness risk (low probability)
- TEST-7 — async: false in sync_all_connections_worker_test (low value)
- TEST-8 — Pre-existing failure not tracked (already known)
- ARCH-7 — dev_routes guard (informational)
