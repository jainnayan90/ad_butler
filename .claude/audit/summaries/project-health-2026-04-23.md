# Project Health Summary — April 23, 2026

## Executive Summary

**Overall Health Score: 75.9/100 — Grade B**

Ad Butler's foundation is solid with strong security posture and well-structured dependencies. However, **context boundary violations** and **concurrency bottlenecks** pose medium-term risks to scalability and maintainability. The system is production-ready but requires architectural cleanup and performance tuning before handling 5000+ ad accounts.

### Weighted Scorecard

| Category | Score | Weight | Contribution |
|---|---|---|---|
| Architecture | 74/100 | 25% | 18.5 |
| Performance | 68/100 | 25% | 17.0 |
| Security | 82/100 | 20% | 16.4 |
| Tests | 79/100 | 20% | 15.8 |
| Dependencies | 82/100 | 10% | 8.2 |
| **TOTAL** | **75.9/100** | **100%** | **75.9** |

### Grade: B (Production-Ready with Caveats)

---

## CRITICAL & HIGH Findings (11 items)

### CRITICAL Severity (6 findings)

1. **[A1-CRITICAL] Ads context violates module boundaries — JOINs Accounts.MetaConnection directly**
   - **Location:** `lib/ad_butler/ads.ex:5,16,25` (scope/2, scope_ad_account/2)
   - **Impact:** Breaks context encapsulation; tightly couples Ads ↔ Accounts
   - **Fix:** Scope against `AdAccount.meta_connection_id` only OR add `Accounts.list_meta_connection_ids_for_user/1`
   - **Status:** Blocking architectural cleanup

2. **[A2-CRITICAL] MetadataPipeline bypasses Ads context with direct Repo.get(AdAccount)**
   - **Location:** `lib/ad_butler/sync/metadata_pipeline.ex:8,32`
   - **Impact:** Sync pipeline operating outside intended abstraction boundary
   - **Fix:** Add `Ads.get_ad_account/1` wrapper, remove direct Repo + AdAccount alias
   - **Status:** Blocking architectural cleanup

3. **[P1-CRITICAL] CPU-bound O(n) validation loop blocks Broadway batcher process**
   - **Location:** `lib/ad_butler/ads.ex:328-344` (bulk_validate/2)
   - **Impact:** Synchronous changesets in Broadway batch callback fully occupy 2-process batcher on large syncs (1000 campaigns = 1000 sequential validations); blocks downstream processing
   - **Risk:** Sync timeout under production load (1000+ ad accounts)
   - **Fix:** Move validation to async GenServer or offload to separate pool

4. **[P2-CRITICAL] Single GenServer serializes all RabbitMQ publishes — timeout risk under sustained load**
   - **Location:** `lib/ad_butler/messaging/publisher.ex:27-29`
   - **Impact:** All callers block on `GenServer.call(__MODULE__, {:publish, payload})`. With sync queue at concurrency 20, up to 20 Oban workers compete on single mailbox; default 5s timeout expires before mailbox drains
   - **Risk:** Worker crashes during sustained sync (timeout exceptions, increased DLQ churn)
   - **Fix:** Publisher process pool OR switch to `GenServer.cast` with AMQP-level flow control

5. **[P3-CRITICAL] N+1 — get_meta_connection! called per ad_account in process_batch_group/1**
   - **Location:** `lib/ad_butler/sync/metadata_pipeline.ex:64`
   - **Impact:** 10 ad accounts sharing one connection = 10 identical DB round trips
   - **Fix:** Load connection once at top of process_batch_group/1, pass into sync_ad_account/2

6. **[P4-CRITICAL] N+1 — one upsert per campaign/ad_set in loop**
   - **Location:** `lib/ad_butler/sync/metadata_pipeline.ex:99,108` (upsert_campaigns/2, upsert_ad_sets/2)
   - **Impact:** 100 campaigns = 100 sequential DB round trips
   - **Fix:** Use `Repo.insert_all/3` with multi-row values + on_conflict + returning

---

### HIGH Severity (5 findings)

7. **[P5-HIGH] Broadway throughput ceiling at ~20 concurrent syncs — settings too conservative**
   - **Location:** `lib/ad_butler/sync/metadata_pipeline.ex:29-34`
   - **Settings:** `batch_size: 10, batcher_concurrency: 2, prefetch_count: 10` → effective ceiling = 20
   - **Impact:** Each sync ~3 sequential Meta API calls (~9s); 1000 connections = ~150s wall time per sweep
   - **Fix:** Raise `batcher_concurrency` to 5–10, `prefetch_count` to 50 → 3–5× throughput improvement
   - **Risk:** Under-utilization of available capacity; slow refresh cycles at scale

8. **[P6-HIGH] list_all_active_meta_connections/1 silently truncates at 1000**
   - **Location:** `lib/ad_butler/accounts.ex:116-131`
   - **Impact:** Connections beyond position 1000 permanently skipped every sweep
   - **Fix:** Implement cursor-based batching
   - **Severity:** Data loss risk at scale

9. **[S1-MEDIUM→HIGH] OAuth error_description reflected into flash without length/content guard**
   - **Location:** `lib/ad_butler_web/controllers/auth_controller.ex:50`
   - **Impact:** Attacker can inject arbitrarily long/misleading strings via OAuth redirect; XSS mitigated by Phoenix HTML escaping but effective for phishing + session bloat
   - **Fix:** Truncate to ≤200 chars OR use fixed generic message; log raw value server-side only

10. **[S2-MEDIUM→HIGH] refresh_token sends access_token as GET query parameter**
    - **Location:** `lib/ad_butler/meta/client.ex:103-125`
    - **Impact:** Token appears in proxy/CDN logs, Erlang HTTP client debug logs
    - **Fix:** Switch to HTTP POST with token in form body (exchange_code already does this)

11. **[S3-MEDIUM] MetadataPipeline: ad_account_id unvalidated — raises Ecto.CastError → DLQ churn**
    - **Location:** `lib/ad_butler/sync/metadata_pipeline.ex:31-44`
    - **Impact:** Non-UUID values crash batch, poison subsequent messages
    - **Fix:** Validate with `Ecto.UUID.cast/1` before Repo.get; Message.failed on :error
    - **Status:** Overlaps with A2 (boundary violation)

---

## Category Deep-Dives

### Architecture (74/100) — B

**Strengths:**
- No compile-time cycles; module naming consistent
- API surface appropriate (Accounts=9, Ads=14, under 30)
- Fan-out ≤2 context imports per module
- Money: all as _cents integers
- Query pinning: all ^ present, no interpolation
- Worker idempotency: unique constraints throughout

**Deductions:**
- **-10:** Context boundary violations (Ads JOINs Accounts, Pipeline direct Repo) — A1, A2
- **-3:** Phoenix 1.8 Scope pattern absent — A3
- **-3:** Scheduler atom key in job args (minor) — A4
- **-7:** Infrastructure for above (error handling, validation chain)

**Action Items:**
1. Extract sync-internal DB access into `AdButler.Ads.Sync` module (pairs with S2)
2. Add `Accounts.list_meta_connection_ids_for_user/1` helper
3. Implement Scope pattern with UUID guards on all context functions

---

### Performance (68/100) — D+

**Strengths:**
- No N+1 in steady-state queries (bulk Repo.insert_all used correctly)
- FK indexes present; composite unique indexes back upserts
- Oban queue separation sensible (sync:20/default:10/analytics:5)
- Oban idempotency: unique window (5 min) prevents fan-out duplicates
- Broadway DLQ correctly routes through RabbitMQ DLX

**Deductions:**
- **-15:** Three CRITICAL concurrency + N+1 patterns (P1, P2, P3, P4) block scaling
- **-8:** Broadway throughput ceiling artificially low (P5)
- **-5:** Silent truncation at 1000 in list_all_active_meta_connections (P6)
- **-4:** Missing database indexes (status columns on campaigns, ad_sets)

**Secondary Issues:**
- ETS table missing `write_concurrency: true` (serializes concurrent writers)
- `SyncAllConnectionsWorker` inserts 1000 rows in one call (causes latency spikes; chunk to 100–200)
- Broadway partition_by_ad_account JSON decoded twice (negligible at low volume)
- list_expiring_meta_connections 70-day window over-fetches (should be 7–14 days)
- process_batch_group crashes entire batch on deleted connection (should fail per-message)

**Action Items:**
1. Add composite indexes: `(ad_account_id, status)` on campaigns, ad_sets
2. Fix N+1 loops (P3, P4) — consolidate to Repo.insert_all calls
3. Tune Broadway settings (batcher_concurrency 5–10, prefetch_count 50)
4. Implement cursor-based batching for list_all_active_meta_connections
5. Add write_concurrency to RateLimitStore ETS table
6. Chunk Oban inserts (100–200 rows per call, not 1000)

---

### Security (82/100) — B+

**Strengths:**
- OAuth CSRF: 32-byte CSPRNG state, server-side storage, secure_compare, 600s TTL
- Session config: http_only, same_site: Lax, secure in prod, signing + encryption
- Authorization: scope/2 on all Ads queries, pinned binds throughout
- RequireAuthenticated: UUID validation before DB lookup; drops/halts on failure
- Rate limiting: PlugAttack on auth routes; Fly header validated via inet.parse_address
- Secret/token logging: redacted, no raw tokens; AMQP sanitized; ErrorHelpers.safe_reason
- Encrypted fields: access_token AES-GCM-256, key validated to 32 bytes at startup
- CSP: default-src 'self', script-src 'self', object-src 'none', frame-ancestors 'none'
- Input validation: no String.to_atom with external input; no raw() in templates
- No sobelow CRITICAL/HIGH issues

**Deductions:**
- **-7:** Session salts hardcoded at compile-time (VCS, OWASP A02) — S1
- **-5:** Dev Cloak key committed (literal base64, VCS) — S2
- **-3:** OAuth error_description unguarded (phishing + bloat) — S3
- **-2:** refresh_token sends token as GET param (log leakage) — S4
- **-1:** Ad_account_id unvalidated in MetadataPipeline (S5, overlaps with A2)

**Action Items:**
1. Load session salts from runtime.exs env for prod (keep static for dev)
2. Move dev Cloak key to System.get_env("CLOAK_KEY_DEV") with .env convention
3. Truncate OAuth error_description to ≤200 chars; log raw value server-side
4. Switch refresh_token to HTTP POST with token in form body
5. Validate ad_account_id with Ecto.UUID.cast before Repo.get

---

### Tests (79/100) — B

**Strengths:**
- verify_on_exit! present in all 6 Mox files (no leaked expectations)
- async: false justified in all Broadway/PlugAttack/ETS tests
- set_mox_from_context correctly paired with async: true (Accounts, TokenRefresh)
- Oban: perform_job/2 throughout; no drain_queue anti-pattern
- Broadway: test_message + assert_receive pattern correct
- SQL sandbox: manual mode + Sandbox.start_owner! correct
- Token encryption: raw DB bytes verified to differ from plaintext
- All 6 OAuth error branches covered
- Rate-limit snooze, unauthorized cancel, retry paths covered
- Integration test correctly tagged :integration, excluded from default run

**Deductions:**
- **-8:** Six MEDIUM test coverage gaps (T1–T6) — critical paths untested
- **-6:** One flaky pattern (Process.sleep in integration test)
- **-1:** Sandbox.allow gap (scheduler process not in test sandbox)

**Critical Coverage Gaps:**
- **[T1]** AuthControllerTest missing set_mox_global (async: false but no setup)
- **[T2]** Five Meta.Client callbacks untested: list_campaigns/3, list_ad_sets/3, list_ads/3, refresh_token/1, get_creative/2
- **[T3]** MetadataPipeline {error, :unauthorized} path untested
- **[T4]** Orphan ad-set drop path untested (compare: orphan ads has test)
- **[T5]** Malformed JSON message path untested (handle_message returns Message.failed but no test)
- **[T6]** parse_budget/1 edge cases: nil, integer, non-numeric string untested

**Action Items:**
1. Add `setup :set_mox_global` to AuthControllerTest
2. Add direct unit tests for 5 untested Meta.Client callbacks
3. Test unauthorized + orphan ad_set paths in MetadataPipeline
4. Test malformed JSON + missing ad_account_id in handle_message
5. Test parse_budget edge cases (nil, integer, non-numeric)
6. Replace Process.sleep(100) in replay_dlq test with AMQP consumer subscription + assert_receive
7. Add Sandbox.allow for scheduler process in scheduler_test

---

### Dependencies (82/100) — B+

**Status:** Healthy. All 29 packages at latest version, no CVEs, no retired packages.

**Scoping:** All correct
- :credo, :mox, :ex_machina, :lazy_html scoped to dev/test only ✓
- :tidewave, :phoenix_live_reload, :esbuild, :tailwind scoped to dev ✓
- :broadway_rabbitmq not scoped (correct, needed in all envs) ✓

**Minor Issue:** mix_audit not in dev deps (optional but useful for license/maintenance auditing)

---

## Top 10 Prioritized Recommendations

| # | Finding | Owner Module | Severity | Est. Effort | Priority |
|---|---|---|---|---|---|
| 1 | Fix context boundary: MetadataPipeline direct Repo.get(AdAccount) | `lib/ad_butler/sync/metadata_pipeline.ex` | CRITICAL | M | P0 |
| 2 | Fix context boundary: Ads JOINs Accounts.MetaConnection | `lib/ad_butler/ads.ex` | CRITICAL | M | P0 |
| 3 | Fix N+1: get_meta_connection per ad_account in process_batch_group | `lib/ad_butler/sync/metadata_pipeline.ex` | CRITICAL | S | P0 |
| 4 | Fix N+1: upsert loops → Repo.insert_all in upsert_campaigns/ad_sets | `lib/ad_butler/sync/metadata_pipeline.ex` | CRITICAL | M | P0 |
| 5 | Remove O(n) validation loop from Broadway batcher; offload to async | `lib/ad_butler/ads.ex:328-344` | CRITICAL | M | P0 |
| 6 | Fix GenServer publish bottleneck: add process pool or switch to cast | `lib/ad_butler/messaging/publisher.ex` | CRITICAL | M | P0 |
| 7 | Implement cursor-based batching for list_all_active_meta_connections | `lib/ad_butler/accounts.ex` | HIGH | M | P1 |
| 8 | Tune Broadway settings: batcher_concurrency 5–10, prefetch_count 50 | `lib/ad_butler/sync/metadata_pipeline.ex` | HIGH | S | P1 |
| 9 | Add database indexes (ad_account_id, status) on campaigns, ad_sets | Migrations | HIGH | S | P1 |
| 10 | Load session salts from env in runtime.exs for prod | `config/runtime.exs` | MEDIUM | S | P1 |

---

## Action Plan

### Immediate (This Week) — P0 Critical Path

These block scaling beyond 1000 ad accounts:

1. **MetadataPipeline boundary violation (A2)**
   - Add `Ads.get_ad_account/1` wrapper function
   - Remove `alias AdButler.Ads.AdAccount` from metadata_pipeline.ex
   - Update `get_meta_connection! ` call to use scoped helper
   - *Effort:* 30 min, 1 test
   - *Owner:* Sync team

2. **N+1: get_meta_connection per ad_account (P3)**
   - Refactor `process_batch_group/1` to load connection once at top
   - Pass connection via `sync_ad_account/2` signature
   - *Effort:* 1 hour, 2–3 tests (batch with multiple accounts)
   - *Owner:* Sync team

3. **N+1: upsert loops (P4)**
   - Consolidate `upsert_campaigns/2` → single `Repo.insert_all/3` call
   - Consolidate `upsert_ad_sets/2` → single call
   - Update returning clause to include :id, :meta_id for FK resolution
   - *Effort:* 2 hours, existing test suite covers
   - *Owner:* Sync team

4. **GenServer publish bottleneck (P2)**
   - Option A: Create publisher process pool (5–10 processes) via dynamic supervisor
   - Option B: Switch to `GenServer.cast` + queue with AMQP-level backpressure
   - Validate with load test: 20 concurrent Oban workers, 1000 ads per sync
   - *Effort:* 3 hours (pool), 4 hours (cast) + 1 hour load test
   - *Owner:* Infrastructure team

5. **O(n) validation in Broadway (P1)**
   - Move changesets out of Broadway batch callback into separate GenServer or task pool
   - Return early on validation error (Message.failed)
   - *Effort:* 2 hours, 2–3 new tests
   - *Owner:* Sync team

### Short-term (Next Sprint) — P1 High-Impact

These improve scalability + reliability:

6. **Ad_account_id validation (S3, A2)**
   - Add `Ecto.UUID.cast/1` guard in `handle_message/3` before Repo.get
   - Return `Message.failed(message, :invalid_id)` on :error
   - *Effort:* 30 min + 1 test

7. **Broadway settings tuning (P5)**
   - Increase `batcher_concurrency` from 2 to 5
   - Increase `prefetch_count` from 10 to 50
   - Load test to confirm 3–5× throughput gain
   - *Effort:* 30 min config + 1 hour load test

8. **Database indexes (P6)**
   - Add composite index `(ad_account_id, status)` on campaigns table
   - Add composite index `(ad_account_id, status)` on ad_sets table
   - Run concurrently to avoid locks
   - *Effort:* 15 min migration + schema

9. **Cursor-based batching (P6)**
   - Replace unbounded query with cursor-based loop in `list_all_active_meta_connections/1`
   - Test with mock 5000+ active connections
   - *Effort:* 1.5 hours + 2 tests

10. **Session salt env load (S1)**
    - Load `session_signing_salt` + `session_encryption_salt` from `runtime.exs` in prod
    - Update prod.exs to validate 32-byte minimum
    - *Effort:* 30 min + verify in staging

### Long-term (Backlog) — P2 Hygiene

These improve maintainability + test coverage:

- **Context cleanup (A1):** Extract sync-internal functions into `AdButler.Ads.Sync` module (blocks public API evolution)
- **Phoenix Scope pattern (A3):** Implement `%Scope{}` struct + guards on all context functions (prevents future web-path bypasses)
- **Test coverage (T1–T6):** Add 8–10 unit tests for untested Meta.Client callbacks + edge cases (parsing, validation)
- **Flaky test (T1):** Replace Process.sleep with AMQP consumer + assert_receive in replay_dlq test
- **OAuth redirect guard (S2):** Truncate error_description to ≤200 chars; log raw value server-side
- **Token log leakage (S3):** Switch refresh_token to HTTP POST
- **Dev Cloak key (S2):** Move to System.get_env("CLOAK_KEY_DEV") with .env convention
- **RateLimitStore concurrency (P7):** Add `write_concurrency: true` to ETS table definition
- **Oban chunk sizing (P8):** Chunk SyncAllConnectionsWorker inserts to 100–200 rows per call
- **Scheduler (W3):** Replace GenServer with Oban cron worker (eliminates single re-schedule risk)

---

## Coverage Validation

| Input File | Represented | Key Findings | Status |
|---|---|---|---|
| arch-review.md | ✓ Yes | 5 (A1, A2, A3, A4, A5) | All critical items extracted |
| perf-audit.md | ✓ Yes | 9 (P1–P9) | All critical + high extracted |
| security-audit.md | ✓ Yes | 5 (S1–S5) | All medium + high extracted |
| test-audit.md | ✓ Yes | 9 (T1–T9) | Coverage gaps documented |
| deps-audit.md | ✓ Yes | 1 (mix_audit suggestion) | Minor issue noted |

**Coverage:** 5/5 files represented. No gaps.

---

## Summary by Risk Level

### CRITICAL (Do Now — Blocks 5k+ ad accounts)
- Boundary violations: A1, A2
- N+1 patterns: P3, P4
- Concurrency bottleneck: P2
- Validation blockage: P1

### HIGH (Do This Sprint — Scalability + Security)
- Broadway throughput: P5
- Silent truncation: P6
- OAuth injection risk: S2
- Token log leakage: S3
- Input validation: S4

### MEDIUM (Do Next Sprint — Maintainability)
- Test coverage gaps: T1–T6
- Session salt hardcoding: S1
- Dev Cloak key exposure: S2
- ETS write concurrency: P7
- Scheduler single re-schedule: W3

---

## Health Trajectory

**Current:** B (75.9/100) — Production-ready for <1000 ad accounts; scaling risks above

**After P0 fixes (1–2 weeks):** A- (85+/100) — Architectural boundaries + N+1 elimination removes scaling risk; GenServer pool ensures publisher reliability

**After P1 fixes (next sprint):** A (88+/100) — Performance optimization + test coverage gaps addressed; ready for 5000+ ad accounts

**After P2 cleanup:** A+ (92+/100) — Context abstraction enforced; scope pattern implemented; test suite comprehensive
