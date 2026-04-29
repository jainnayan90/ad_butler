# Consolidated Review Summary

**Strategy**: Compress (5 files, ~18k tokens → ~7k tokens)
**Verdict**: 4 BLOCKERs, 6 WARNINGs, 9 SUGGESTIONs

---

## BLOCKER FINDINGS (4 total)

### 1. `upsert_ad_health_score` return value silently discarded
**Severity**: CRITICAL — silent DB failure, no Oban retry
**Files**: 
- `lib/ad_butler/workers/budget_leak_auditor_worker.ex:66` (Oban + Elixir reviewer)
- `lib/ad_butler/analytics.ex:117`

**Issue**: `Enum.each` at line 66 discards `{:ok, _} | {:error, _}` tuples. A DB failure causes the job to return `:ok` to Oban, preventing retries.

**Fix**: Collect results with `Enum.map`, detect any `{:error, _}`, and return `{:error, reason}`.

---

### 2. AuditSchedulerWorker missing `unique:` guard on scheduler itself
**Severity**: CRITICAL — redundant fan-out on node restart
**File**: `lib/ad_butler/workers/audit_scheduler_worker.ex:9`

**Issue**: `use Oban.Worker, queue: :audit, max_attempts: 3` lacks `unique:` guard. Child `BudgetLeakAuditorWorker` jobs have per-account dedup, but if the cron scheduler fires twice (e.g., node restart mid-cron), it enqueues two full fan-outs to all accounts.

**Fix**: Add `unique: [period: 21_600]` to the `use Oban.Worker` declaration.

---

### 3. Scheduler uses N individual `Oban.insert/1` calls (1,000 round-trips)
**Severity**: CRITICAL — performance/DB load
**File**: `lib/ad_butler/workers/audit_scheduler_worker.ex:23-27`

**Issue**: With 1,000 ad accounts, 1,000 sequential DB round-trips instead of bulk insert. Project already uses `Oban.insert_all/1` in `token_refresh_sweep_worker.ex` and `sync_all_connections_worker.ex`.

**Fix**: Replace loop with:
```elixir
ad_accounts
|> Enum.map(fn aa ->
  BudgetLeakAuditorWorker.new(
    %{"ad_account_id" => aa.id},
    unique: [period: 21_600, keys: [:ad_account_id]]
  )
end)
|> Oban.insert_all()
```

---

### 4. `stalled_learning` heuristic has zero test coverage
**Severity**: CRITICAL — untested code path with weight 3
**File**: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`

**Issue**: Worker implements `stalled_learning` but covers `dead_spend`, `cpa_explosion` (skip only), `bot_traffic`, `placement_drag`. Both trigger and skip paths required per CLAUDE.md.

**Fix**: Add tests for trigger and skip paths.

---

### 5. Acknowledge test only verifies HTML, not DB state
**Severity**: CRITICAL — persistence not validated
**File**: `test/ad_butler_web/live/finding_detail_live_test.exs:56-68`

**Issue**: `render_click(view, "acknowledge")` asserts HTML shows "Acknowledged" but never asserts `Repo.get!(Finding, finding.id).acknowledged_at`. A bug updating assigns without persisting would pass.

**Fix**: Add assertion: `assert Repo.get!(Finding, finding.id).acknowledged_at != nil`

---

## WARNING FINDINGS (6 total)

### 1. `handle_info(:reload_on_reconnect)` without connection guard in mount
**File**: `lib/ad_butler_web/live/findings_live.ex:101-122`

Handler exists but mount never sends the message. Either wire `if connected?(socket), do: send(self(), :reload_on_reconnect)` in mount or remove dead handler.

---

### 2. `cpa_explosion` only has skip-path test
**File**: `test/ad_butler/workers/budget_leak_auditor_worker_test.exs`

Missing trigger path: elevated 30d baseline CPA should emit `cpa_explosion` finding.

---

### 3. Mass assignment in Finding changeset — lifecycle fields castable
**File**: `lib/ad_butler/analytics/finding.ex:39-58`

`Finding.changeset/2` casts both content AND lifecycle fields (`:resolved_at`, `:acknowledged_at`, `:acknowledged_by_user_id`) permissively. Today safe (acknowledge built server-side), but `create_finding/1` shares the changeset. Future user-controlled update path could mark findings resolved or spoof acks.

**Fix**: Split into role-specific changesets:
- `create_changeset(f, attrs)` — content only
- `acknowledge_changeset(f, user_id)` — `change(f, acknowledged_at: ..., acknowledged_by_user_id: user_id)` no user input

---

### 4. Cron collision: both schedulers fire at `"0 */6 * * *"`
**File**: `config/config.exs:138,145`

`AuditSchedulerWorker` and `TokenRefreshSweepWorker` both at 00:00, 06:00, 12:00, 18:00 UTC. DB load spike.

**Fix**: Stagger to `"3 */6 * * *"` for audit scheduler, keeping token refresh at `"0 */6 * * *"`.

---

### 5. No `timeout/1` on BudgetLeakAuditorWorker
**File**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:11`

For large accounts, `load_48h_insights` may take minutes. Only Lifeline 30-min rescue guards runaway jobs.

**Fix**: Add:
```elixir
@impl Oban.Worker
def timeout(_job), do: :timer.minutes(10)
```

---

### 6. `audit_scheduler_worker_test.exs` uses `Repo` without module alias
**File**: `test/ad_butler/workers/audit_scheduler_worker_test.exs:68,114`

`Repo` called without top-level `alias AdButler.Repo`. `import Ecto.Query` inline at line 108.

**Fix**: Move both to module top-level.

---

## SUGGESTION FINDINGS (9 total — grouped by theme)

### Code Quality & Naming

1. **`with true <- boolean` non-idiomatic** (`budget_leak_auditor_worker.ex:226,228`)
   - `with true <- conversions_3d > 0` better absorbed via pattern matching on `{:ok, %{cpa_cents: baseline_cpa}}`.

2. **`upsert_ad_health_score` name contradicts behaviour** (`lib/ad_butler/analytics.ex:117`)
   - Always INSERTs (append-only), never upserts. Rename to `insert_ad_health_score` to match `@moduledoc`.

3. **`@doc false` on `defp` is a no-op** (`budget_leak_auditor_worker.ex:375`)
   - Only affects public `def`. Remove it.

4. **Dead-code alias stub** (`lib/ad_butler_web/live/finding_detail_live.ex:182`)
   - `_ = Ads` stub. Remove both alias and stub; restore when actually used.

5. **Duplicate private helpers across LiveViews**
   - `severity_badge_class/1` and `kind_label/1` copy-pasted between `FindingsLive` and `FindingDetailLive`. Extract to `AdButlerWeb.FindingComponents`.

---

### Testing & Validation

6. **`filter_changed` handle_event never tested via `render_change`** (`findings_live_test.exs`)
   - Filters tested via URL params only. Add `render_change(view, "filter_changed", %{"severity" => "high"})`.

7. **Smoke test assertion is weak** (`audit_scheduler_worker_test.exs:116`)
   - `findings_count >= 1` should be `== 1` to catch accidental duplication.

8. **`analytics_test.exs` bypasses context API** 
   - Direct `Repo.update_all` to set `resolved_at`. Prefer factory `:resolved_at` override or context function.

9. **Suppress `mc` warnings by removal, not underscore** (`findings_live_test.exs:54,84`)
   - `_ = mc` suppresses warnings. Remove `mc` from pattern match entirely.

---

## DECONFLICTION LOG

| Issue | Sources | Resolution |
|-------|---------|-----------|
| `upsert_ad_health_score` return discarded | Elixir reviewer, Oban specialist | Kept both sources in BLOCKER #1; single fix covers all |
| AuditSchedulerWorker `unique:` missing | Iron laws judge, Oban specialist | Kept both sources in BLOCKER #2; single fix |
| Pool size comment stale | Oban specialist only | Moved to general improvements (not blocking) |
| `@doc false` on `defp` | Elixir reviewer, Oban specialist | Deduped into single SUGGESTION item #3 |

---

## FALSE POSITIVES

**Race on findings dedup** (Oban reviewer) — MARKED FALSE POSITIVE
- Agent suggested a partial unique index to prevent race conditions.
- **Reality**: This index already exists in `priv/repo/migrations/20260427000002_create_findings.exs` as `UNIQUE INDEX CONCURRENTLY ... WHERE resolved_at IS NULL`.
- **Action**: No fix required.

---

## COVERAGE

| File | Represented | Key Findings |
|------|---|---|
| iron-laws.md | Yes | BLOCKER #2, WARNING #1, general pass notes |
| testing.md | Yes | BLOCKERs #4, #5, WARNINGs #2, #6 |
| elixir.md | Yes | BLOCKER #1, WARNINGs #3, SUGGESTIONs #2, #3, #4, #5 |
| oban.md | Yes | BLOCKERs #1, #3, WARNINGs #4, #5, false positive, SUGGESTIONs |
| security.md | Yes | WARNINGs #3 (lifecycle fields), SUGGESTIONs (offset DoS, evidence size) |

✅ All 5 input files represented.

---

## NEXT STEPS (Priority Order)

1. **Fix BLOCKERs immediately** — all block PR merge:
   - `upsert_ad_health_score` error handling
   - Add `unique:` to `AuditSchedulerWorker`
   - Convert scheduler to `Oban.insert_all`
   - Add `stalled_learning` tests
   - Fix acknowledge test to assert DB state

2. **Fix WARNINGs before merge** — security/correctness:
   - Split Finding changesets (lifecycle vs. content)
   - Stagger cron schedules
   - Add `timeout/1` to `BudgetLeakAuditorWorker`
   - Fix test module imports

3. **Address SUGGESTIONs in next PR** — quality/maintainability:
   - Refactor heuristic loops
   - Extract duplicate components
   - Improve test coverage
   - Remove dead code stubs
