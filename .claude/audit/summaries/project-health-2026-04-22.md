# Project Health Audit — ad_butler
**Date**: 2026-04-22  
**Overall Score: 79/100 — Grade C (Needs Attention)**

---

## Category Scores

| Category | Score | Grade | Weight | Weighted |
|----------|-------|-------|--------|---------|
| Architecture | 72/100 | C | 20% | 14.4 |
| Performance | 62/100 | D | 25% | 15.5 |
| Security | 92/100 | A | 25% | 23.0 |
| Test Quality | 81/100 | B | 15% | 12.2 |
| Dependencies | 95/100 | A | 15% | 14.3 |
| **Overall** | **79/100** | **C** | — | — |

---

## Critical Issues (act now)

### Architecture
**A1** — `Ads` context JOINs `Accounts.MetaConnection` schema directly (`ads.ex:5,16,25`). Cross-context query coupling — context boundary violation.

**A2** — `MetadataPipeline` calls `Repo.get(AdAccount, ...)` directly, bypassing the `Ads` context (`metadata_pipeline.ex:8,32`).

### Performance
**P1** — N+1: `get_meta_connection!` called once per ad_account in `process_batch_group/1` (`metadata_pipeline.ex:64`). Fix: load once, pass into `sync_ad_account/2`.

**P2** — N+1: `upsert_campaigns/2` and `upsert_ad_sets/2` issue one `INSERT...ON CONFLICT` per row. 100 campaigns = 100 DB round trips. Fix: `Repo.insert_all/3` with multi-row upsert.

### Security
**S3** — `MetadataPipeline` passes raw JSON `ad_account_id` to `Repo.get` without UUID validation. Malformed message → `Ecto.Query.CastError` → DLQ churn (`metadata_pipeline.ex:31-44`).

**S4** — `ReplayDlq` replays all DLQ payloads with no validation. Poison messages re-enter the pipeline (`replay_dlq.ex:33-37`).

---

## Warnings (address soon)

| # | Area | Finding |
|---|------|---------|
| A3 | Arch | No Phoenix 1.8 `%Scope{}` pattern — unscoped functions dangerous on web paths |
| A4 | Arch | Oban job args use atom key in `Scheduler` — should be string keys |
| P3 | Perf | `Scheduler` GenServer fires once, never re-schedules — replace with Oban cron |
| P4 | Perf | `list_all_active_meta_connections/0` unbounded — no LIMIT/pagination |
| P5 | Perf | 4 list functions select full rows including `raw_jsonb` blobs |
| S1 | Sec | Session salts hardcoded at compile-time — load from env in `runtime.exs` |
| S2 | Sec | Dev Cloak key committed to repo — use `System.get_env` + `.env` convention |
| T1 | Test | `Process.sleep(100)` in `replay_dlq_test.exs:33` — flaky integration test |
| T2 | Test | `Sandbox.allow` gap in `scheduler_test.exs` — Scheduler process not covered |
| T5 | Test | `upsert_ad_set/2`, `upsert_ad/2` have no direct context-level idempotency tests |

---

## Strengths

- **Security posture is excellent** (92/100) — OAuth CSRF, session management, HSTS, CSP, encrypted + redacted tokens, PlugAttack, all queries parameterised
- **Dependencies fully current** (95/100) — all 29 packages at latest versions, no CVEs
- **Test infrastructure solid** (81/100) — Mox discipline, Broadway test patterns, no sleep in non-integration tests, all 5 worker branches covered
- **Money handling correct** — all budgets as `_cents` bigint, no floats
- **Worker idempotency** — unique constraints on all Oban workers, terminal errors cancel cleanly
- **Third-party boundaries** — `Meta.Client` and `Publisher` behind behaviours, injectable in tests

---

## Action Plan

### Immediate (before next deploy)
1. Fix `ads.ex` scope functions — remove `MetaConnection` alias, scope via `AdAccount` only
2. Fix `metadata_pipeline.ex` — add `Ads.get_ad_account/1`, remove direct `Repo` call
3. Add `Ecto.UUID.cast/1` validation in `metadata_pipeline.ex` handle_message
4. Fix N+1 in `process_batch_group/1` — load MetaConnection once per batch group

### Short-term (next sprint)
5. Bulk-upsert `campaigns` and `ad_sets` with `Repo.insert_all/3`
6. Add session salt env vars in `runtime.exs`
7. Fix `Scheduler` → replace with `Oban.Plugin.Cron`
8. Add `LIMIT`/pagination to `list_all_active_meta_connections/0`
9. Fix `Sandbox.allow` gap in scheduler test
10. Add direct `upsert_ad_set/2`, `upsert_ad/2` idempotency tests

### Long-term
11. Add `%Scope{}` pattern per Phoenix 1.8 conventions
12. Add `select/2` projections to list queries (drop `raw_jsonb` from list views)
13. Add ReplayDlq validation + `--confirm` flag for production use
14. Re-audit `handle_event` authorization when first LiveView is added
