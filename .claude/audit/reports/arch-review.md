# Architecture Audit — 2026-04-23

**Score: 74/100**

| Criterion | Score | Deductions |
|---|---|---|
| Context boundaries | 15/25 | -5 Ads→Accounts JOIN; -5 Pipeline direct Repo |
| Module naming | 15/15 | — |
| Fan-out <5 | 15/15 | — |
| API surface <30 | 15/15 | — |
| No compile cycles | 15/15 | No cycles found |
| Folder conventions | 12/15 | -3 Phoenix 1.8 Scope absent |

## Issues

**[A1-CRITICAL] Ads context JOINs Accounts.MetaConnection directly — ads.ex:5,16,25**
`defp scope/2` and `defp scope_ad_account/2` alias and join against `Accounts.MetaConnection`. Ads must not query Accounts schemas directly. Fix: scope against AdAccount.meta_connection_id only, or add `Accounts.list_meta_connection_ids_for_user/1` returning IDs.

**[A2-CRITICAL] MetadataPipeline calls Repo.get(AdAccount) directly — metadata_pipeline.ex:8,32**
Bypasses Ads context. Add `Ads.get_ad_account/1` and remove direct Repo + AdAccount alias from the pipeline.

**[A3-MODERATE] Phoenix 1.8 Scope pattern absent**
Project runs Phoenix 1.8.3 but no %Scope{} struct. list_all_active_meta_connections/0 has no scope guard — safe now (Scheduler-only) but structurally dangerous on web paths.

**[A4-MINOR] Oban job args use atom key in Scheduler — scheduler.ex:16**
`%{meta_connection_id: connection.id}` should be `%{"meta_connection_id" => connection.id}`. Workers pattern-match on string keys. Works today via Jason encoding but violates Oban iron law.

**[A5-MINOR] RequireAuthenticated plug uses hardcoded "/" not ~p"/"**
Inconsistent with verified routes used elsewhere.

## Clean Areas

Money: all budgets as _cents integers. Query pinning: all ^ present. Worker idempotency: unique constraints on all workers. Third-party wrapping: Meta.Client and Publisher behind behaviours. Supervision: correct env gating. Security headers: CSP, CSRF, rate-limiting present. Encryption: access_token Encrypted.Binary with redact: true. API surface: Accounts=9, Ads=14 — well under 30. Fan-out: max 2 context imports per module.
