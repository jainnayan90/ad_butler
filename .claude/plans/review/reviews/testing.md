## Test Review — Pass 3

**Verdict: REQUIRES CHANGES — 1 Blocker · 2 Warnings · 4 Suggestions**

All prior pass findings resolved. New issues below.

---

## BLOCKER

**B1 — DigestMailer total_count overflow branch never exercised**
`test/ad_butler/notifications/digest_mailer_test.exs`

`DigestMailer.build/4` has `total_count \\ nil`. When `total_count > length(findings)`, both `build_text_body/3` and `build_html_body/3` emit an overflow trailer. Every test uses 3-arity form — both overflow branches are permanently dead in tests. Was S1 in Pass 2 (not addressed).

Fix: add test `build(user, findings, "daily", 10)` with 2 findings → assert `"and 8 more findings"` in text_body and html_body.

---

## WARNINGS

**W1 — "no active connections" test missing empty-queue assertion**
`test/ad_butler/workers/digest_scheduler_worker_test.exs:39`

Only `:ok` return checked. A bug enqueuing stale jobs would pass. Add `assert all_enqueued(worker: DigestWorker) == []`. Was in Pass 2, not yet fixed.

**W2 — user_without_findings/0 and user_with_finding/1 duplicated verbatim**
`test/ad_butler/notifications/notifications_test.exs:9-24` vs `test/ad_butler/workers/digest_worker_test.exs:10-25`

Identical private helpers in two files. Extract to `test/support/notifications_fixtures.ex`. Was S3 in Pass 2, not yet fixed.

---

## SUGGESTIONS

**S1 — CRLF header-injection guard untested**
`test/ad_butler/notifications/digest_mailer_test.exs`
`safe_display_name/1` CRLF-strip path never hit. Add: `name: "Bad\r\nActor"`, assert `\r`/`\n` absent from `email.to` display name.

**S2 — 100-char truncation in safe_display_name/1 untested**
Same function — `String.slice(0, 100)` on >100-char name has no coverage.

**S3 — DigestWorker missing {:error, reason} clause and test**
`lib/ad_butler/workers/digest_worker.ex:18-21`
`case` only handles `:ok` and `{:skip, :no_findings}`. Mox-stubbed SMTP failure test needed.

**S4 — Fan-out test never asserts exact job count**
`test/ad_butler/workers/digest_scheduler_worker_test.exs:10-19`
Two users checked individually; `length(all_enqueued(worker: DigestWorker)) == 2` not asserted.
