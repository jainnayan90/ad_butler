## Iron Law Violations — Pass 3

**Files scanned:** 4 new + 2 modified
**Violations found:** 1 WARNING · 1 SUGGESTION

### WARNING

**[Law #2] Unhandled `{:error, reason}` in DigestWorker.perform/1**
`lib/ad_butler/workers/digest_worker.ex:18-21`

`Notifications.deliver_digest/2` returns `:ok | {:skip, :no_findings} | {:error, term()}`. The `case` block omits `{:error, reason}`. On SMTP failure Oban catches `CaseClauseError` and retries, but CLAUDE.md requires every `{:error, reason}` to be explicitly propagated or logged.

Fix: `{:error, reason} -> {:error, reason}`.

### SUGGESTION

**[Performance] Full User structs loaded when only IDs needed**
`lib/ad_butler/workers/digest_scheduler_worker.ex:17`

`list_users_with_active_connections/0` returns full structs (including Cloak-encrypted fields); worker uses only `&1.id`.

### Confirmed Fixed (passes 1+2)

HTML injection, unique constraints, get_user!/1, Repo boundary, tenant scope, string keys, structured logging, PII, @moduledoc/@doc, header injection — all clean.
