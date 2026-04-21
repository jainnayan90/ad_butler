# Triage: Week-1 Pass-3

Date: 2026-04-21  
Source: `.claude/plans/week-1-pass3-fixes/reviews/week-1-pass3-review.md`

## Fix Queue

- [x] [W1] Add `"expires_in" => 86400` to upsert-flow stub in `auth_controller_test.exs:111`
- [x] [W2] Add nil-session test to `auth_controller_test.exs` (cold callback hit with no session)
- [x] [W3] Extract `safe_reason/log_safe_reason` to `AdButler.ErrorHelpers`, update both callers
- [x] [W4] Add comment to `token_refresh_worker.ex:96` explaining snooze + sweep-recovery rationale
- [x] [S1] Rename `conn` to `verified_conn` in `auth_controller.ex:37` with/else pattern
- [x] [S2] Remove redundant `id` parameter from `do_refresh/2` in `token_refresh_worker.ex:37`
- [x] [S3] Add comment to `plug_attack.ex` that XFF fallback is only trustworthy on Fly.io

## Skipped

- S4 (img-src data: / CSP report-uri) — acceptable for now
- S5 (schedule_refresh struct constraint) — intentional design per plan

## Deferred

None.
