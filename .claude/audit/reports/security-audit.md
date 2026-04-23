# Security Audit

**Score: 92/100**

| Criterion | Score | Notes |
|---|---|---|
| No sobelow critical issues | 30/30 | clean |
| No sobelow high issues | 20/20 | clean |
| Authorization in all handle_events | 15/15 | no LiveViews yet |
| No String.to_atom with input | 10/10 | clean |
| No raw() with untrusted content | 10/10 | clean |
| Secrets in runtime.exs only | 7/15 | session salts static; dev Cloak key in repo |

## Issues

**[S1-MEDIUM] Session salts hardcoded at compile time — config.exs:17-19**
session_signing_salt / session_encryption_salt are static literals in VCS. OWASP A02.
Fix: load from env in runtime.exs for prod.

**[S2-LOW] Dev Cloak key committed to repo — dev.exs:96-101**
Literal base64 key. If dev DB dump leaks, encrypted tokens recoverable.
Fix: System.get_env("CLOAK_KEY_DEV") with .env convention.

**[S3-MEDIUM] MetadataPipeline: ad_account_id unvalidated — metadata_pipeline.ex:31-44**
Pre-existing W4. Non-UUID value raises Ecto.Query.CastError → DLQ churn. OWASP A03/A04.
Fix: Ecto.UUID.cast/1 before Repo.get; Message.failed on :error.

**[S4-MEDIUM] ReplayDlq replays without validation — replay_dlq.ex:33-37**
Pre-existing W9. Poisoned payloads re-enter pipeline. No env guard, unbounded limit.
Fix: Jason.decode each payload, skip malformed; cap limit; require --confirm for prod.

## Clean Areas

OAuth state CSRF, session management (renew on login, drop on logout), scope/2 in Ads context, all queries parameterized, CSP/HSTS/frame-ancestors, filter_parameters covers all sensitive fields, RequireAuthenticated validates UUID, PlugAttack on auth routes, encrypted + redacted access_token, AMQP reason sanitized in logs, no String.to_atom/raw/binary_to_term patterns.
