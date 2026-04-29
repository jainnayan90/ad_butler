# Triage: week-2-auditor-findings
**Decision**: Fix all BLOCKERs + all WARNINGs. Approach: follow review suggestions as written.
**Fix Queue**: 11 items | **Skipped**: 0 | **Deferred**: 9 SUGGESTIONs

---

## Fix Queue

### BLOCKERs

- [ ] [B1] **Silent DB failure, no Oban retry** — `budget_leak_auditor_worker.ex:66`
  `Enum.each` discards `upsert_ad_health_score` return value. Change to `Enum.map`, detect `{:error, _}`, return `{:error, reason}` so Oban reschedules.

- [ ] [B2] **AuditSchedulerWorker missing `unique:` on itself** — `audit_scheduler_worker.ex:9`
  Add `unique: [period: 21_600]` to `use Oban.Worker` declaration.

- [ ] [B3] **Scheduler uses N individual `Oban.insert/1` calls** — `audit_scheduler_worker.ex:23-27`
  Replace `Enum.each` loop with `Enum.map` + `Oban.insert_all/1`, matching the pattern in `token_refresh_sweep_worker.ex` and `sync_all_connections_worker.ex`.

- [ ] [B4] **`stalled_learning` heuristic untested** — `budget_leak_auditor_worker_test.exs`
  Add tests for both trigger path (ad_set in LEARNING > 7d, conversions < 50) and skip path (same ad_set, sufficient conversions).

- [ ] [B5] **Acknowledge test verifies HTML only, not DB** — `finding_detail_live_test.exs:56-68`
  After `render_click(view, "acknowledge")`, add `Repo.get!(Finding, finding.id)` assertion on `acknowledged_at != nil` and `acknowledged_by_user_id == user.id`.

### WARNINGs

- [ ] [W1] **Dead `handle_info(:reload_on_reconnect)` without `connected?` guard** — `findings_live.ex:101`
  Wire in mount: `if connected?(socket), do: send(self(), :reload_on_reconnect)` or remove the handler entirely.

- [ ] [W2] **`cpa_explosion` only has skip-path test** — `budget_leak_auditor_worker_test.exs`
  Add trigger-path test: seed 30d baseline CPA then recent rows with elevated CPA; assert `cpa_explosion` finding created.

- [ ] [W3] **`Finding.changeset/2` casts lifecycle fields permissively** — `finding.ex:39-58`
  Split into:
  - `create_changeset(f, attrs)` — casts `[:ad_id, :ad_account_id, :kind, :severity, :title, :body, :evidence]` only
  - `acknowledge_changeset(f, user_id)` — `change(f, acknowledged_at: DateTime.utc_now(), acknowledged_by_user_id: user_id)` (no user-supplied map)
  Update `create_finding/1` → `create_changeset`, `acknowledge_finding/2` → `acknowledge_changeset`.

- [ ] [W4] **Cron collision: audit fires same time as token refresh** — `config.exs:145`
  Change `AuditSchedulerWorker` cron from `"0 */6 * * *"` to `"3 */6 * * *"`.

- [ ] [W5] **No `timeout/1` on `BudgetLeakAuditorWorker`** — `budget_leak_auditor_worker.ex:11`
  Add:
  ```elixir
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)
  ```

- [ ] [W6] **`Repo` used without alias in scheduler test** — `audit_scheduler_worker_test.exs`
  Add `alias AdButler.Repo` and `import Ecto.Query` at module top-level.

---

## Skipped
None.

---

## Deferred (SUGGESTIONs — next PR)
- `get_latest_health_score/1` → rename to `unsafe_get_latest_health_score/1`
- `upsert_ad_health_score` → rename to `insert_ad_health_score`
- `severity_badge_class/1` + `kind_label/1` → extract to `AdButlerWeb.FindingComponents`
- `with true <- boolean` non-idiomatic in `check_cpa_explosion`
- `@doc false` on `defp` + `_ = Ads` stub → remove
- Add `render_change` test for `filter_changed` event
- Smoke test `>= 1` → `== 1`
- `analytics_test.exs` bypasses context API for `resolved_at`
- Remove `_ = mc` suppression hackery in test files
