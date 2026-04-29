# Triage: Week 3 — Notifications + Digest Workers

**Date:** 2026-04-29
**Source review:** `.claude/plans/review/reviews/week3-notifications-review.md`
**Result:** 15 to fix · 2 skipped

---

## Fix Queue

### BLOCKERs

- [x] **B1** — HTML injection in DigestMailer HTML body
  - `lib/ad_butler/notifications/digest_mailer.ex:29-44`
  - Escape `f.title` and `f.severity` via `Phoenix.HTML.html_escape/1` + `safe_to_string/1` (or switch to `.heex` template). Apply to both HTML and text body variants.

- [x] **B2** — DigestWorker missing unique constraint
  - `lib/ad_butler/workers/digest_worker.ex:4`
  - Add `unique: [period: {25, :hours}, keys: [:user_id, :period]]` to `use Oban.Worker`.

- [x] **B3** — Atom keys in Oban cron args
  - `config/config.exs:147-148`
  - Change `%{period: "daily"}` → `%{"period" => "daily"}` and `%{period: "weekly"}` → `%{"period" => "weekly"}`.

---

### WARNINGs

- [x] **W1** — `get_user!` crash-loops on deleted users
  - `lib/ad_butler/workers/digest_worker.ex:10`
  - Replace `Accounts.get_user!(user_id)` with `Accounts.get_user(user_id)`; return `{:cancel, "user not found"}` on `nil`.

- [x] **W2** ★ Iron Law — No tenant isolation test for DigestWorker
  - `test/ad_butler/workers/digest_worker_test.exs`
  - Add test: create user A with high finding, run DigestWorker for user B, assert no email sent.

- [x] **W3** — `Notifications.deliver_digest/2` has no direct test coverage
  - Create `test/ad_butler/notifications/notifications_test.exs`
  - Test both `:ok` path (user with findings) and `{:skip, :no_findings}` path (user with 0 or only low findings).

- [x] **W4** — `assert_enqueued` missing `"period"` key
  - `test/ad_butler/workers/digest_scheduler_worker_test.exs:30`
  - Add `"period" => "daily"` to all `assert_enqueued` calls. Also add `assert length(all_enqueued(worker: DigestWorker)) == <expected_count>`.

- [x] **W5** — DigestSchedulerWorker no self-dedup
  - `lib/ad_butler/workers/digest_scheduler_worker.ex:4`
  - Add `unique: [period: {23, :hours}, fields: [:queue, :worker, :args]]` to `use Oban.Worker`.

- [x] **W6** — `Oban.insert_all/1` result discarded
  - `lib/ad_butler/workers/digest_scheduler_worker.ex:17`
  - Bind result, filter for `%Ecto.Changeset{}` entries, log warning with count if any.

- [x] **W7** — SMTP TLS no peer verification
  - `config/runtime.exs:176-183`
  - Add `tls_options: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), server_name_indication: String.to_charlist(System.fetch_env!("SMTP_HOST")), depth: 3]` to SMTP config.

- [x] **W8** ★ Iron Law — Email PII in Swoosh logs
  - `config/config.exs:116-126`
  - Add `"email"`, `"smtp_password"`, `"smtp_username"` to `:filter_parameters` list.

- [x] **W9** — Unbounded `list_all_active_users/0`
  - `lib/ad_butler/accounts.ex:244-251` + `lib/ad_butler/workers/digest_scheduler_worker.ex`
  - Add pagination/chunking: stream users in batches of 500, use chunked `Oban.insert_all/1`.

---

### Suggestions

- [x] **S2** — DigestMailer `to` display name uses email instead of user name
  - `lib/ad_butler/notifications/digest_mailer.ex:12`
  - Change `to({user.email, user.email})` → `to({user.name, user.email})`. Update test assertion.

- [x] **S3** — No timeout callback on DigestWorker
  - `lib/ad_butler/workers/digest_worker.ex`
  - Add `@impl Oban.Worker` + `def timeout(_job), do: :timer.seconds(30)`.

- [x] **S4** — `list_high_medium_findings_since/2` has no limit
  - `lib/ad_butler/analytics.ex`
  - Cap query at 50 rows. Add "and N more findings" trailer in email when total > 50.

- [x] **S5** — No `List-Unsubscribe` header
  - `lib/ad_butler/notifications/digest_mailer.ex`
  - Add `header("List-Unsubscribe", "<mailto:unsubscribe@#{host}>")`. Requires signed per-user token or mailto fallback.

---

## Skipped

- **S1** — `deliver_digest/2` uses `if` instead of multi-clause heads — not selected
- **S6** — Hardcoded `From:` address `noreply@adbutler.app` — not selected
