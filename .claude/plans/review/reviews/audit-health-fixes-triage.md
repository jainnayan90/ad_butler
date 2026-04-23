# Triage: Audit Health Fixes — 2026-04-22
**Decision**: Fix all 15 findings (2 must-fix + 9 warnings + 4 suggestions)

---

## Fix Queue

### Must Fix
- [ ] **MF-1** `lib/ad_butler/workers/sync_all_connections_worker.ex:14-18` — Replace `Enum.each` + `Oban.insert/1` with `Oban.insert_all/1` to propagate insert errors
- [ ] **MF-2** `config/runtime.exs`, `lib/ad_butler_web/endpoint.ex:13-14` — Investigate session-salt compile vs runtime mismatch; verify in a release build with rotated salts + LiveView sign-in

### Warnings
- [ ] **W1** `lib/ad_butler/ads.ex:46-47` — Rename `get_ad_account/1` → `get_ad_account_for_sync/1`, add `@doc "INTERNAL — bypasses tenant scope"`
- [ ] **W2** `config/dev.exs:103` — Make dev Cloak fallback obvious (IO.warn or comments) + add 32-byte guard
- [ ] **W3** `lib/ad_butler/sync/metadata_pipeline.ex:37-40` — Unify `with` else failure reasons to `:invalid_payload` for all non-nil, non-not-found branches
- [ ] **W4** `lib/ad_butler/ads.ex:72,104` — Tighten `bulk_upsert_*` specs: `{non_neg_integer(), [%{id: binary(), meta_id: binary()}]}`
- [ ] **W5** `lib/ad_butler/sync/metadata_pipeline.ex:154` — Replace `String.to_integer/1` with `Integer.parse/1` + fallback in `parse_budget/1`
- [ ] **W6** `config/config.exs:18-19,29` — Move literal salts out of `config.exs` into `dev.exs`/`test.exs`
- [ ] **W7** `config/runtime.exs:43-45` — Add `server: true` unconditionally in prod block (don't rely on `PHX_SERVER`)
- [ ] **W8** `.envrc:7` — Run `git log --all -- .envrc`; rotate `CLOAK_KEY` if pushed; replace real key with placeholder
- [ ] **W9** `lib/ad_butler/ads.ex:14-26` — Add comment on `scope/2` and `scope_ad_account/2` documenting the extra DB round-trip

### Suggestions
- [ ] **S1** `config/config.exs` — Offset `SyncAllConnectionsWorker` cron to `"5 */6 * * *"` for cleaner dashboard isolation
- [ ] **S2** `lib/ad_butler/workers/fetch_ad_accounts_worker.ex` — Add `def timeout(_job), do: :timer.minutes(5)`
- [ ] **S3** `lib/ad_butler/sync/scheduler.ex` — Add `@spec` to `schedule_sync_for_connection/1` (was lost when GenServer removed)
- [ ] **S4** `test/ad_butler/ads_test.exs`, `test/ad_butler/sync/scheduler_test.exs` — (a) Add `bulk_upsert_campaigns/2` direct conflict-resolution test; (b) add empty-connections test for `SyncAllConnectionsWorker`; (c) remove/scope redundant `Repo.aggregate(:count)` assertions

---

## Skipped
_(none)_

## Deferred
_(none)_
