# Oban Worker Review — Week 7

⚠️ EXTRACTED FROM AGENT MESSAGE (Write tool unavailable in agent env)

## Summary

Both workers well-structured and mirror BudgetLeakAuditor pattern faithfully. Unique-key config, queue isolation, timeout, kill-switch all solid. Three issues need attention before prod: one **BLOCKER** (non-atomic finding/score write breaks retry idempotency), two **WARNINGS**.

Iron Laws: all honoured. String keys, no structs in args, `unique` fields include `:args` so `:keys` filtering works — the solved-pattern at `.claude/solutions/oban/unique-keys-requires-args-in-fields-20260429.md` is correctly applied.

---

## BLOCKER

### Finding creation and score write are non-atomic; crash between them causes silently lost health scores on retry
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:211-250`

`maybe_emit_finding/5` is called inside `Enum.reduce`. If all findings are inserted successfully but `Analytics.bulk_insert_fatigue_scores/1` then raises (or process dies), the job retries. On retry, `unsafe_list_open_finding_keys/1` returns those findings as already-open, so every ad hits `:skipped` branch and produces no `entry`. `entries` ends up empty, `bulk_insert_fatigue_scores([])` is a no-op, and the health score rows are lost for the entire 6-hour bucket — silently, with `:ok` return.

BudgetLeakAuditorWorker avoids this by using `reduce_while` + `with` so a finding-creation failure halts immediately and bubbles `{:error, reason}`.

**Fix options:**
1. Write scores for ads regardless of whether the finding was skipped (entry generated even in `:skipped` branch — upsert is idempotent so safe)
2. Write `bulk_insert_fatigue_scores` *before* emitting findings, so on retry the scores already exist
3. Wrap both writes in `Repo.transaction/1`

---

## WARNING

### `maybe_emit_finding/5` return value discarded; finding DB errors logged but don't fail job
`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:227`

```elixir
maybe_emit_finding(ad_id, ad_account.id, score, factors, open_findings)
# return value discarded — {:error, reason} is silently dropped
```

The `{:error, reason}` branch logs and returns `{:error, reason}`, but caller ignores it. Job returns `:ok` and Oban marks it complete, permanently losing the finding. BudgetLeakAuditor's `apply_check/5` correctly halts on `{:error, reason}`.

**Fix:** Capture return and propagate: if any `maybe_emit_finding` returns `{:error, reason}`, function should return `{:error, reason}` to let Oban retry.

### Kill-switch uses `Application.get_env` on a compile-time config key
`lib/ad_butler/workers/audit_scheduler_worker.ex:33`

`config :ad_butler, :fatigue_enabled, false` in `config/config.exs` is baked at compile time in Mix releases. The moduledoc implies it can "pause without redeploying," only true if set via `config/runtime.exs` using `System.get_env/2`.

**Fix:** Move to `config/runtime.exs` if true hot-toggle needed:
```elixir
config :ad_butler, fatigue_enabled: System.get_env("FATIGUE_ENABLED", "true") == "true"
```
Or correct the moduledoc claim.

---

## SUGGESTIONS

- **Healthy ads get no fatigue score row, unlike BudgetLeakAuditorWorker** which writes zero-score rows for all ads. Downstream queries joining both columns need NULL handling.
- **`six_hour_bucket/0` duplicated** verbatim in both workers. Extract to shared private module.
- **Pool size comment in `config.exs` is stale.** Total worker slots now: 10+20+5+5+5+5 = 50. Comment says `>= 25`; recommend `>= 60`.

---

## Queue & Config Assessment

- `fatigue_audit: 5` concurrency — appropriate for DB-bound I/O heuristics
- `timeout/1` returning `:timer.minutes(10)` — correct, matches Lifeline's `rescue_after: 30min`
- `max_attempts: 3` — conservative and appropriate for a 6-hour scheduled audit
- Cron `"3 */6 * * *"` — 6-hour period aligns with `unique: [period: 21_600]`; 3-min offset avoids contention with `SyncAllConnectionsWorker`
- Lifeline and Pruner plugins both configured

## Idempotency Assessment

- **AuditSchedulerWorker:** Fully idempotent
- **CreativeFatiguePredictorWorker:** Idempotent on the finding side; partially non-idempotent on the health score side due to BLOCKER above. The upsert itself (`on_conflict: {:replace, [:fatigue_score, :fatigue_factors, :inserted_at]}`) correctly preserves budget worker columns — no cross-worker clobber risk.
