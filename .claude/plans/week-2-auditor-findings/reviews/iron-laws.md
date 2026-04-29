# Iron Law Review — week-2-auditor-findings
⚠️ EXTRACTED FROM AGENT MESSAGE (agent had no Write permission)

## Summary
Files scanned: 7 | Violations: 4 (1 BLOCKER, 1 WARNING, 2 SUGGESTION)

---

## BLOCKER

### AuditSchedulerWorker missing `unique:` on the scheduler itself
**File**: `lib/ad_butler/workers/audit_scheduler_worker.ex:9`
`use Oban.Worker, queue: :audit, max_attempts: 3` — no `unique:` guard.

Child `BudgetLeakAuditorWorker` jobs have per-account dedup (`unique: [period: 21_600, keys: [:ad_account_id]]`), but if the scheduler fires twice (node restart mid-cron), it enqueues two full fan-outs.
**Fix**: Add `unique: [period: 21_600]` to the `use Oban.Worker` declaration.

---

## WARNING

### `handle_info(:reload_on_reconnect)` without `connected?` guard in mount
**File**: `lib/ad_butler_web/live/findings_live.ex:101-122`

The handler exists but nothing sends the message — no `if connected?(socket), do: send(self(), :reload_on_reconnect)` in mount. Either wire it in mount or remove the dead handler.

---

## SUGGESTIONS

### `acknowledge` event lacks explicit authorization comment
**File**: `lib/ad_butler_web/live/finding_detail_live.ex:35-45`
Functionally safe (context uses `get_finding!(user, id)`), but a comment noting the authorization chain would help reviewers.

### `ad_account_id` filter not validated against user's accounts
**File**: `lib/ad_butler_web/live/findings_live.ex:79-84`
`severity` and `kind` are validated against allowlists; `ad_account_id` passes through. Tenant scope in `paginate_findings/2` prevents leaks, but defence-in-depth would validate the ID against `Ads.list_ad_accounts(current_user)` first.

---

## PASS (clean items)
- Both LiveViews: zero direct `Repo` calls. PASS.
- `get_finding!/2` and `paginate_findings/2` both route through `scope_findings/2`. PASS.
- `mount/3` makes no DB queries — data loaded in `handle_params/3`. PASS.
- `stream(:findings, ..., reset: true)` used correctly. PASS.
- Pagination: `@per_page 50`, `total_pages`, `<.pagination />`. PASS.
- No float for money. PASS.
- All query vars pinned with `^`. PASS.
- Oban string keys correct in both workers. PASS.
- `@moduledoc` and `@doc` on all 7 files and public functions. PASS.
