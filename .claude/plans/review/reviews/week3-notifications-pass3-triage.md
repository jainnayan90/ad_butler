# Triage: Week 3 Notifications — Pass 3

**Date:** 2026-04-29
**Source:** week3-notifications-pass3-review.md
**Selection:** All findings — 2 Blockers · 8 Warnings · 7 Suggestions

---

## Fix Queue

### BLOCKERS

- [x] **B1** — `DigestWorker.perform/1` missing `{:error, reason}` clause *(Iron Law #2 auto-approved)*
  `lib/ad_butler/workers/digest_worker.ex:18-21`
  Add `{:error, reason} -> {:error, reason}` arm to inner `case Notifications.deliver_digest(...)`.

- [x] **B2** — `DigestMailer.build/4` total_count overflow branch never tested
  `test/ad_butler/notifications/digest_mailer_test.exs`
  Add test: `build(user, findings, "daily", 10)` with 2 findings → assert "and 8 more findings" in text_body and html_body.

### WARNINGS

- [x] **W1** — `period` not validated in `DigestWorker.perform/1`
  `lib/ad_butler/workers/digest_worker.ex:12`
  Add `when period in ["daily", "weekly"]` guard to perform/1 head. Add fallback clause: `def perform(%Oban.Job{args: args}), do: {:cancel, "invalid period: #{inspect(Map.get(args, "period"))}"}`.

- [x] **W2** — `safe_display_name/1` returns `""` (truthy) for all-CRLF input
  `lib/ad_butler/notifications/digest_mailer.ex:11,30`
  After stripping, check `if stripped == "", do: nil, else: stripped`. Ensures fallback to `user.email`.

- [x] **W3** — `DigestMailer.build/4` missing `@spec`
  `lib/ad_butler/notifications/digest_mailer.ex:7`
  Add: `@spec build(User.t(), [Finding.t()], String.t(), non_neg_integer() | nil) :: Swoosh.Email.t()`

- [x] **W4** — `SMTP_PORT` parsed with `String.to_integer/1`
  `config/runtime.exs` (SMTP port config)
  Use `Integer.parse/1` with explicit error message, matching `RABBITMQ_POOL_SIZE` pattern in the same file.

- [x] **W5** — `timeout/1` 30s may be tight
  `lib/ad_butler/workers/digest_worker.ex:26`
  Bump to `:timer.seconds(60)`.

- [x] **W6** — Daily and weekly cron both fire at 08:00 Monday
  `config/config.exs` (cron schedules)
  Change daily cron from `"0 8 * * *"` to `"0 8 * * 2-7"` (skip Mondays) so users receive only the weekly digest on Mondays.

- [x] **W7** — "no active connections" test missing empty-queue assertion
  `test/ad_butler/workers/digest_scheduler_worker_test.exs:39`
  Add: `assert all_enqueued(worker: DigestWorker) == []`

- [x] **W8** — `user_without_findings/0` and `user_with_finding/1` duplicated
  `test/ad_butler/notifications/notifications_test.exs:9-24` + `test/ad_butler/workers/digest_worker_test.exs:10-25`
  Extract both helpers to `test/support/notifications_fixtures.ex`. Update both test files to import from there.

### SUGGESTIONS

- [x] **S1** — Test CRLF strip in `safe_display_name/1`
  `test/ad_butler/notifications/digest_mailer_test.exs`
  Add test: `name: "Bad\r\nActor"` → assert `\r`/`\n` absent from `email.to` display name.

- [x] **S2** — Test 100-char truncation in `safe_display_name/1`
  `test/ad_butler/notifications/digest_mailer_test.exs`
  Add test: name with 150 chars → assert display name length ≤ 100.

- [x] **S3** — `DigestWorker` `{:error, reason}` path test
  `test/ad_butler/workers/digest_worker_test.exs`
  Mox-stub `Mailer.deliver` to return `{:error, :timeout}` → assert `perform_job/2` returns `{:error, :timeout}`.

- [x] **S4** — Fan-out test missing exact job count
  `test/ad_butler/workers/digest_scheduler_worker_test.exs:10-19`
  Add: `assert length(all_enqueued(worker: DigestWorker)) == 2`

- [x] **S5** — `deliver_digest/2` uses `if findings == []` instead of function head
  `lib/ad_butler/notifications.ex:20`
  Extract `do_deliver/3` private function with empty-list head match.

- [x] **S6** — `DigestSchedulerWorker` loads full User structs but only uses `.id`
  `lib/ad_butler/workers/digest_scheduler_worker.ex:17`
  Update `list_users_with_active_connections/0` query to `select: [:id]` only (keep return type `[%User{id: binary()}]`).

- [x] **S7** — SMTP error reason may leak email address to Oban logs
  `lib/ad_butler/notifications.ex:25-28`
  Return `{:error, :delivery_failed}` and log the real reason via `Logger.warning("digest delivery failed", reason: inspect(reason), user_id: user.id)`.

---

## Skipped

None.

## Deferred

- **S3** — `DigestWorker {:error}` path test deferred. `AdButler.Mailer` has no behaviour/Mox setup; Swoosh test adapter always returns `{:ok, _}`. Requires adding a `MailerBehaviour` module first.
