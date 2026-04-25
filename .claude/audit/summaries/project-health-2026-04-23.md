# AdButler — Project Health Report

**Date:** 2026-04-23
**Branch:** module_documentation_and_audit_fixes (post-review fixes applied)
**Overall Grade: B (75/100)**

---

## Score Summary

| Category | Score | Grade |
|----------|-------|-------|
| Architecture | 72/100 | B− |
| Performance | 80/100 | B |
| Security | 80/100 | B |
| Tests | 82/100 | B |
| Dependencies | 60/100 | D |
| **Overall** | **75/100** | **B** |

---

## Critical / High Priority Issues

### ARCH-1 — `Ads` context depends on `Accounts` at runtime on every query
`lib/ad_butler/ads.ex:26, 31` — `scope/2` and `scope_ad_account/2` call `Accounts.list_meta_connection_ids_for_user/1`, issuing an extra SELECT per call. A dashboard rendering campaigns + ad_sets + ads costs 6–16 round-trips.

### ARCH-2 — `setup_rabbitmq_topology` fails silently after all retries
`lib/ad_butler/application.ex` — three retries exhausted → logs error, continues. Publisher starts, messages published to undeclared exchange are silently dropped.

### SEC-1 — Meta Graph API tokens in URL query strings (OWASP A02)
`lib/ad_butler/meta/client.ex` — six GET endpoints pass `access_token` via query params. Tokens visible in Fly proxy logs and Meta server access logs. `refresh_token` (POST+form) was fixed; apply same fix to all GET endpoints using `Authorization: Bearer` header.

### PERF-1 — Broadway `prefetch_count` under-provisioned
`lib/ad_butler/sync/metadata_pipeline.ex` — `batcher_concurrency: 5` × `batch_size: 25` = 125 in-flight but `prefetch_count: 50` throttles delivery. Throughput capped at ~40% of capacity. Set `prefetch_count: 150`.

### DEPS-1 — `plug_attack` unmaintained since 2022 (security-sensitive layer)
Security-critical rate-limiting with no upstream maintenance for 18+ months. Evaluate replacement.

---

## Medium Priority Issues

| ID | Area | Issue |
|----|------|-------|
| ARCH-3 | Architecture | Broadway comment has stale throughput math (says batch_size: 10, actually 25) |
| ARCH-4 | Architecture | `MetadataPipeline` calls `Accounts` directly — cross-namespace, undocumented intent |
| ARCH-5 | Architecture | Bulk upsert scaffolding duplicated 3× in ads.ex (~80 lines) |
| PERF-2 | Performance | `TokenRefreshSweepWorker` up to 500 sequential `Oban.insert/1` calls — use `insert_all` |
| SEC-2 | Security | OAuth callback rate limit 10/min too generous; tighten to 3/min |
| TEST-1 | Tests | 3 public `Accounts` functions untested: `get_meta_connections_by_ids/1`, `stream_active_meta_connections/1`, `list_meta_connection_ids_for_user/1` |
| TEST-2 | Tests | `TokenRefreshSweepWorker` `{:error, :all_enqueues_failed}` path has no test |
| TEST-3 | Tests | `MetadataPipeline` — `list_ads` error paths (unauthorized, rate limit) untested |
| DEPS-2 | Dependencies | `broadway_rabbitmq ~> 0.8` locked at 0.8.2 (2023); upstream has 0.9+ |
| DEPS-3 | Dependencies | `req ~> 0.5` constraint blocks 0.6+ upgrade |

---

## Low Priority / Suggestions

| ID | Area | Issue |
|----|------|-------|
| SEC-3 | Security | Dev Cloak key defaults to all-zeros base64 |
| SEC-4 | Security | `dev_routes` guard is compile_env only — not gated on `config_env() == :dev` |
| TEST-4 | Tests | `list_ads/2` `:ad_set_id` filter path untested |
| TEST-5 | Tests | Integration test `wait_for_queue_depth` 500ms deadline may be too tight for CI |
| DEPS-4 | Dependencies | `ex_machina` scoped to `[:test, :dev]` — should be `only: :test` |
| DEPS-5 | Dependencies | `tidewave ~> 0.1` too loose; tighten to `~> 0.5` |

---

## Missing Tools (Immediate Adds)

| Tool | Why |
|------|-----|
| `sobelow ~> 0.13` | Phoenix-specific OWASP scan; critical for OAuth + token handling |
| `dialyxir ~> 1.4` | Type checking for Meta API client and Oban arg shapes |

---

## Action Plan

### Immediate (before next production deployment)
1. Move Meta API GET tokens to `Authorization: Bearer` header (SEC-1)
2. Set `prefetch_count: 150` in Broadway (PERF-1)
3. Add `sobelow` to dev deps + precommit alias
4. Tighten OAuth callback rate limit to 3/min (SEC-2)

### Short-term (next sprint)
5. Fix `Ads.scope/2` to accept connection IDs as parameter, removing Accounts dependency (ARCH-1)
6. Make topology setup fail-fast or gate Publisher startup on successful topology (ARCH-2)
7. Replace `Oban.insert/1` loop in `TokenRefreshSweepWorker` with `insert_all` (PERF-2)
8. Add tests for 3 missing Accounts functions (TEST-1)
9. Scope `ex_machina` to `only: :test` (DEPS-4)

### Long-term (backlog)
10. Evaluate `plug_attack` replacement — `hammer` or custom plug (DEPS-1)
11. Upgrade `broadway_rabbitmq` to `~> 0.9` with full integration test run (DEPS-2)
12. Add `dialyxir`
13. Deduplicate bulk upsert scaffolding in ads.ex (ARCH-5)
14. Add missing test coverage: `list_ads` error paths, sweep worker failure, Accounts streaming (TEST-2, TEST-3)

---

## What's Solid

- Encryption: Cloak AES-GCM on access tokens; `@derive Inspect` + `redact: true`; filter_parameters clean
- Auth flow: 256-bit OAuth state, secure_compare, session rotation on login, live socket disconnect on logout
- Oban idempotency: string keys, unique constraints on all 4 workers
- Bulk upserts: `on_conflict: {:replace}`, correct conflict targets, minimal returning projection
- Index coverage: all FK columns indexed; composite status indexes; partial index for token sweep
- Publisher pool: `:atomics` round-robin (worker 0 included); `pending_connected` avoids busy-polling
- Broadway N+1 fix: `get_meta_connections_by_ids/1` batches single WHERE IN per batch
- Test quality: Mox with verify_on_exit!, realistic factories, Sandbox.mode(:manual) correct, Oban.Testing throughout
