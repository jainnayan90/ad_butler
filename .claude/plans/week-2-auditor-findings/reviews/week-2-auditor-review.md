# Review: week-2-auditor-findings
**Verdict: REQUIRES CHANGES**
4 BLOCKERs · 6 WARNINGs · 9 SUGGESTIONs
302 tests passing · Credo clean · No Iron Law failures

---

## BLOCKERs (must fix before merge)

### B1 — `upsert_ad_health_score` return silently discarded, no Oban retry
`lib/ad_butler/workers/budget_leak_auditor_worker.ex:66`
`Enum.each` discards `{:ok, _} | {:error, _}`. DB failure → job returns `:ok` → Oban never retries.
Fix: `Enum.map` + detect any `{:error, _}` → return `{:error, reason}`.

### B2 — AuditSchedulerWorker lacks `unique:` on itself
`lib/ad_butler/workers/audit_scheduler_worker.ex:9`
Node restart mid-cron fires two fan-outs over all accounts. Child job dedup prevents double-auditing, but scheduler itself queries all accounts twice.
Fix: `use Oban.Worker, queue: :audit, max_attempts: 3, unique: [period: 21_600]`

### B3 — Scheduler uses N individual `Oban.insert/1` calls
`lib/ad_butler/workers/audit_scheduler_worker.ex:23-27`
1,000 ad accounts → 1,000 sequential DB round-trips. Project already uses `Oban.insert_all/1` in token_refresh_sweep_worker and sync_all_connections_worker for this exact pattern.
Fix:
```elixir
ad_accounts
|> Enum.map(&BudgetLeakAuditorWorker.new(%{"ad_account_id" => &1.id},
     unique: [period: 21_600, keys: [:ad_account_id]]))
|> Oban.insert_all()
```

### B4 — `stalled_learning` heuristic has zero test coverage
`test/ad_butler/workers/budget_leak_auditor_worker_test.exs`
Worker implements stalled_learning (weight 3) but neither trigger nor skip paths are tested. CLAUDE.md: every context function needs at least one test.

### B5 — Acknowledge test verifies HTML only, not DB persistence
`test/ad_butler_web/live/finding_detail_live_test.exs:56-68`
`render_click(view, "acknowledge")` asserts HTML but never reads `Repo.get!(Finding, finding.id).acknowledged_at`. A bug that updates assigns without persisting would pass.

---

## WARNINGs (fix before merge)

**W1** — `handle_info(:reload_on_reconnect)` dead handler in FindingsLive (`findings_live.ex:101`)
Nothing sends the message — no `if connected?(socket), do: send(...)` in mount. Wire or remove.

**W2** — `cpa_explosion` only has skip-path test — missing trigger path test.

**W3** — `Finding.changeset/2` casts lifecycle fields (`:acknowledged_at`, `:resolved_at`, `:acknowledged_by_user_id`) alongside content fields. Today safe, but a future user-controlled update path could spoof acks or hide findings. Split into `create_changeset/2` (content only) + `acknowledge_changeset/2` (no user-supplied map).

**W4** — Cron collision: `AuditSchedulerWorker` at `"0 */6 * * *"` fires same time as `TokenRefreshSweepWorker`. DB load spike. Change to `"3 */6 * * *"`.

**W5** — No `timeout/1` on `BudgetLeakAuditorWorker`. Large accounts → runaway minutes. Only Lifeline's 30-min rescue acts. Add `def timeout(_job), do: :timer.minutes(10)`.

**W6** — `audit_scheduler_worker_test.exs`: `Repo` and `import Ecto.Query` used without top-level aliases.

---

## SUGGESTIONs (next PR)

**Code quality:**
- `with true <- boolean` non-idiomatic in `check_cpa_explosion` — use pattern match directly
- `upsert_ad_health_score` name contradicts append-only behaviour — rename to `insert_ad_health_score`
- `@doc false` on `defp` at worker:375 — no-op, remove
- `_ = Ads` alias stub in `finding_detail_live.ex:182` — remove both
- `severity_badge_class/1` and `kind_label/1` copy-pasted across both LiveViews — extract to `AdButlerWeb.FindingComponents`

**Testing:**
- `filter_changed` event never tested via `render_change` — add one case
- Smoke test `findings_count >= 1` → `== 1`
- `analytics_test.exs` uses `Repo.update_all` for `resolved_at` — prefer factory override
- Remove `_ = mc` by removing `mc` from pattern match

---

## FALSE POSITIVE (noted)
Oban reviewer flagged missing partial unique index for findings dedup race. **Already exists** in `20260427000002_create_findings.exs` as `UNIQUE INDEX CONCURRENTLY ... WHERE resolved_at IS NULL`. No fix needed.

---

## Clean / PASS
- Tenant isolation: `scope_findings/2` enforces MetaConnection join on all user-facing queries. PASS.
- Both LiveViews: zero direct `Repo` calls. PASS.
- Auth: `/findings` routes inside `:authenticated` live_session. PASS.
- SQL injection: all vars pinned with `^`. PASS.
- XSS: no `raw/1`, HEEx auto-escape, strict CSP. PASS.
- Oban string keys, args store IDs only. PASS.
- `@moduledoc`/`@doc` on all 7 new modules and all public functions. PASS.
- `stream/3` with `reset: true`, pagination in FindingsLive. PASS.
