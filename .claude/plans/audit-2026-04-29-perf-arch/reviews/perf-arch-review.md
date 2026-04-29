# Review: audit-2026-04-29-perf-arch

**Date**: 2026-04-29
**Verdict**: REQUIRES CHANGES
**Issues**: 2 BLOCKERs, 5 WARNINGs, 5 SUGGESTIONs

---

## BLOCKERs

### [BLOCKER] `bulk_insert_health_scores/1` has no unit tests
**File**: `test/ad_butler/analytics_test.exs` (missing)
**Source**: testing-reviewer
The function is a new public context function. Worker tests exercise it end-to-end only. The empty-list fast-path, upsert conflict clause, and `:ok` return are untested in isolation.
**Fix**: Add `describe "bulk_insert_health_scores/1"` covering: empty list → `:ok`; single entry inserts; second call with same `(ad_id, computed_at)` upserts instead of duplicating.

### [BLOCKER] `list_open_finding_keys/1` has no unit tests
**File**: `test/ad_butler/analytics_test.exs` (missing)
**Source**: testing-reviewer
New public function central to the MapSet deduplication optimisation. Correctness depends on it correctly excluding resolved findings. Zero tests exist for it.
**Fix**: Add tests for: `[]` → `MapSet.new()`; open findings return `{ad_id, kind}` tuples; resolved findings (with `resolved_at` set) are excluded.

---

## WARNINGs

### [WARNING] `scope_findings/2` fires two extra queries per user-facing call
**File**: `lib/ad_butler/analytics.ex:263-266`
**Source**: elixir-reviewer
Every call to `paginate_findings`, `get_finding!`, `get_finding`, and `acknowledge_finding` now pays two SELECT round-trips (mc_ids → ad_account_ids) before the findings query. The old JOIN approach was one query.
**Fix**: Collapse into one query via subquery or JOIN, or at minimum cache the mc_ids lookup per request. Low urgency for current traffic but will regress at scale.

### [WARNING] `bulk_insert_health_scores/1` silently discards the insert count
**File**: `lib/ad_butler/analytics.ex:153-162`
**Source**: elixir-reviewer + iron-law-judge (duplicate, keep this one)
`Repo.insert_all/3` returns `{count, nil}`. The count is dropped with no logging. A schema drift or mis-configured conflict_target could silently produce 0 inserted rows.
**Fix**: `{count, _} = Repo.insert_all(...); if count == 0, do: Logger.warning("bulk_insert_health_scores: 0 rows inserted", expected: length(entries))`

### [WARNING] `apply_check/5` adds kind to acc even on `:skipped`
**File**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:148-154`
**Source**: elixir-reviewer
When `maybe_emit_finding/4` returns `:skipped`, the kind is still prepended to `acc`. `fired_kinds` / `fired_by_ad` implies "newly emitted" but actually means "detected (including already-open)". Misleads future readers; health score `leak_factors` will include de-duped findings.
**Fix**: Either rename to `detected_kinds` with a comment, or exclude `:skipped` from acc if health scores should only reflect newly-created findings.

### [WARNING] `finding_factory` and `ad_health_score_factory` use `build(:ad)` for FK fields
**File**: `test/support/factory.ex:94-113`
**Source**: testing-reviewer
Both factories call `build(:ad)` (not `insert(:ad)`). ExMachina generates a UUID for the primary key, so `ad.id` is a valid UUID string — but it doesn't exist in the DB. If the `findings` or `ad_health_scores` tables have FK constraints on `ad_id`, any `insert(:finding)` / `insert(:ad_health_score)` using factory defaults (no explicit `ad_id:` override) will hit a FK violation. All current tests provide explicit overrides so tests pass, but the factory is a trap.
**Fix**: Change `build(:ad)` → `insert(:ad)` in both factory definitions.

### [WARNING] `Ads.list_ad_account_ids_for_mc_ids/1` has no tests
**File**: `test/ad_butler/ads_test.exs` (missing)
**Source**: testing-reviewer
The entire tenant-scoping chain in `scope_findings/2` flows through this function. No tests exist verifying it maps mc_ids → correct ad_account_ids, or that the empty-list guard short-circuits.
**Fix**: Add two tests: `[]` returns `[]`; given one MC's IDs it returns only that MC's ad account IDs.

---

## SUGGESTIONs

### [SUGGESTION] `list_open_finding_keys/1` should be named `unsafe_` or have a doc warning
**File**: `lib/ad_butler/analytics.ex:118`
**Source**: security-reviewer
No tenant scope. Only safe because the caller derives `ad_ids` from a single scoped ad account. Naming convention elsewhere uses `unsafe_` prefix (e.g. `unsafe_list_30d_baselines/1`). A future caller from a LiveView could silently bypass tenant isolation.
**Fix**: Rename to `unsafe_list_open_finding_keys/1` and update caller, or add `@doc` warning: "INTERNAL — not tenant-scoped, worker-only. Never call from user-facing code."

### [SUGGESTION] `upsert_ad_account/2` doc should warn about caller responsibility
**File**: `lib/ad_butler/ads.ex:165`
**Source**: security-reviewer
Signature changed from `%MetaConnection{}` struct (implicit scope signal) to raw binary. A future caller passing a user-supplied UUID could hijack another tenant's row. No current exploit — caller is the sync worker only.
**Fix**: Add to `@doc`: "Caller MUST verify `meta_connection_id` ownership before calling. Never invoke from a controller/LiveView with a user-supplied UUID."

### [SUGGESTION] `Decimal.new` bypasses changeset validation without comment
**File**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:93`
**Source**: elixir-reviewer
`Repo.insert_all` skips changesets, so `validate_number(:leak_score, 0..100)` is silently bypassed. The `min(100)` cap in `compute_leak_score/1` guards it in practice, but no comment explains the bypass.
**Fix**: Add inline comment: `# changeset validation intentionally skipped; score is capped 0..100 by compute_leak_score/1`

### [SUGGESTION] `list_open_finding_keys/1` pipe style inconsistency
**File**: `lib/ad_butler/analytics.ex:122-128`
**Source**: elixir-reviewer
Uses `Repo.all(from f in Finding, ...) |> MapSet.new()` — mixed style vs rest of module which pipes `Schema |> where() |> Repo.all()`.
**Fix**: `from(f in Finding, where: ..., select: ...) |> Repo.all() |> MapSet.new()`

### [SUGGESTION] `_ = mc` suppression noise in three LiveView tests
**File**: `test/ad_butler_web/live/findings_live_test.exs:61,89,179`
**Source**: testing-reviewer
`mc` is destructured in test pattern heads but not used, suppressed with `_ = mc`. Misleads readers.
**Fix**: Remove `mc` from those test pattern match heads.

---

## PRE-EXISTING (not in this diff, noted for awareness)

- `FindingsLive`: `ad_accounts_list` assigned as plain list (should be stream) — `lib/ad_butler_web/live/findings_live.ex:207-213`
- `FindingDetailLive`: no explicit authorization guard in `handle_event("acknowledge")` — context re-scopes but no LiveView-layer guard

---

## Security verdict: PASS
Tenant isolation preserved in the new two-query `scope_findings/2`. All new queries use pinned `^` bindings. No SQL injection vectors. Schema FK change (belongs_to → field) has no security regression. `acknowledge_finding` re-scopes on every event.
