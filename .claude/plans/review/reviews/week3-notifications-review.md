# Code Review: Week 3 — Notifications + Digest Workers

**Date:** 2026-04-29
**Branch:** main (uncommitted changes)
**Files reviewed:**
- `lib/ad_butler/notifications.ex` (new)
- `lib/ad_butler/notifications/digest_mailer.ex` (new)
- `lib/ad_butler/workers/digest_worker.ex` (new)
- `lib/ad_butler/workers/digest_scheduler_worker.ex` (new)
- `lib/ad_butler/accounts.ex` (modified)
- `lib/ad_butler/analytics.ex` (modified)
- `config/config.exs` (modified)
- `config/runtime.exs` (modified)
- `test/ad_butler/notifications/digest_mailer_test.exs` (new)
- `test/ad_butler/workers/digest_worker_test.exs` (new)
- `test/ad_butler/workers/digest_scheduler_worker_test.exs` (new)

**Agents:** elixir-reviewer · oban-specialist · security-analyzer · testing-reviewer · iron-law-judge

---

## Verdict: REQUIRES CHANGES

**3 Blockers · 9 Warnings · 6 Suggestions**

---

## BLOCKERS (must fix before merge)

### B1 — HTML injection in DigestMailer HTML body
**`lib/ad_butler/notifications/digest_mailer.ex:29-44`**
*(flagged by: iron-law-judge, elixir-reviewer, security-analyzer)*

`f.title` and `f.severity` are interpolated unescaped into the HTML email string. Finding titles come from Meta API (ad/creative names — user-controllable in Ads Manager). A title containing `<script>` or `<a href="phishing">` renders executable HTML in every recipient's email client. CRLF in `title` also forges fake rows in the text body.

```elixir
# Current — XSS vector
"<td style='padding:8px'>#{f.title}</td>"

# Fix — escape before interpolating
defp h(v), do: v |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
"<td style='padding:8px'>#{h(f.title)}</td>"
```

Apply `h/1` to every `f.title` and `f.severity` interpolation in both HTML and text bodies. Consider switching to a `.heex` template to get auto-escaping for free.

---

### B2 — DigestWorker has no unique constraint — duplicate emails on retry
**`lib/ad_butler/workers/digest_worker.ex:4`**
*(flagged by: oban-specialist, iron-law-judge)*

No `unique:` option. Oban job retries (e.g., transient SMTP error) or a manual re-trigger send the same user a second digest. `Notifications.deliver_digest/2` has no internal idempotency guard.

```elixir
use Oban.Worker,
  queue: :notifications,
  max_attempts: 3,
  unique: [period: {25, :hours}, keys: [:user_id, :period]]
```

---

### B3 — Atom keys in Oban cron args
**`config/config.exs:147-148`**
*(flagged by: elixir-reviewer, oban-specialist)*

```elixir
# Current — atom keys
args: %{period: "daily"}

# Required — string keys
args: %{"period" => "daily"}
```

`Oban.Testing.perform_job/2` in tests does NOT go through JSON serialisation — it passes the map verbatim. Atom keys make tests and production behave differently; the test suite silently passes while production would fail if the pattern-match ever tightened.

---

## WARNINGS (strong recommendation to fix)

### W1 — `get_user!` crash-loops on deleted users
**`lib/ad_butler/workers/digest_worker.ex:10`**
*(flagged by: iron-law-judge, oban-specialist, security-analyzer)*

`Accounts.get_user!(user_id)` raises `Ecto.NoResultsError` when the user is deleted. This burns all 3 retry attempts into `discarded` and pollutes error dashboards. Follow the `TokenRefreshWorker` pattern:

```elixir
case Accounts.get_user(user_id) do
  nil -> {:cancel, "user not found"}
  user -> deliver(user, period)
end
```

---

### W2 — No tenant isolation test for DigestWorker
*(flagged by: testing-reviewer, iron-law-judge, elixir-reviewer)*

CLAUDE.md: "Tenant isolation tests are non-negotiable." `Analytics.list_high_medium_findings_since/2` scopes by user's MetaConnection IDs, but no test verifies user B's job does not deliver user A's findings.

```elixir
test "does not email findings belonging to another user" do
  _user_a = user_with_finding("high")
  user_b  = user_without_findings()
  assert :ok = perform_job(DigestWorker, %{"user_id" => user_b.id, "period" => "daily"})
  assert_no_email_sent()
end
```

---

### W3 — `Notifications.deliver_digest/2` has no direct test coverage
**`test/ad_butler/notifications/`**
*(flagged by: testing-reviewer)*

New public context function — both `:ok` and `{:skip, :no_findings}` paths are only exercised indirectly through DigestWorker. CLAUDE.md: every context function gets at least one test. Add `notifications_test.exs`.

---

### W4 — `assert_enqueued` missing `"period"` key
**`test/ad_butler/workers/digest_scheduler_worker_test.exs:30`**
*(flagged by: testing-reviewer)*

`assert_enqueued` does subset matching — omitting the `"period"` key means a regression that drops it from job args would go undetected. Also: add `assert length(all_enqueued(worker: DigestWorker)) == 2` to catch duplicate fan-out.

---

### W5 — DigestSchedulerWorker has no self-dedup
**`lib/ad_butler/workers/digest_scheduler_worker.ex:4`**
*(flagged by: oban-specialist, security-analyzer)*

If the scheduler job is still running when the next cron fires, a parallel job double-fans-out, doubling all DigestWorker jobs. Add:

```elixir
unique: [period: {23, :hours}, fields: [:queue, :worker, :args]]
```

---

### W6 — `Oban.insert_all/1` result discarded in DigestSchedulerWorker
**`lib/ad_butler/workers/digest_scheduler_worker.ex:17`**
*(flagged by: oban-specialist)*

Insert failures are silent. Follow `AuditSchedulerWorker`'s pattern — inspect the result for `%Ecto.Changeset{}` entries and log errors.

---

### W7 — SMTP TLS does not verify peer
**`config/runtime.exs:176-183`**
*(flagged by: security-analyzer)*

`tls: :always` without `tls_options:`. gen_smtp does not verify peer certificates by default — SMTP credentials can be intercepted by a MITM.

```elixir
tls_options: [
  verify: :verify_peer,
  cacerts: :public_key.cacerts_get(),
  server_name_indication: String.to_charlist(System.fetch_env!("SMTP_HOST")),
  depth: 3
]
```

---

### W8 — Email PII leaks via Swoosh logs
**`config/config.exs:116-126`**
*(flagged by: security-analyzer)*

Swoosh logs `to:` on delivery. CLAUDE.md forbids PII in logs. Add `"email"`, `"smtp_password"`, `"smtp_username"` to `:filter_parameters`. Consider `config :swoosh, log_level: :debug` to suppress delivery logs in dev.

---

### W9 — Unbounded user list in DigestSchedulerWorker
**`lib/ad_butler/accounts.ex:244-251`**
*(flagged by: security-analyzer)*

`list_all_active_users/0` loads all users into memory before building all jobs. Fine at current scale, fragile at 10k+ users. Stream via `Stream.chunk_every(500)` + chunked `Oban.insert_all/1`.

---

## SUGGESTIONS

**S1** — `deliver_digest/2` uses `if` inside body instead of multi-clause function heads (`notifications.ex:15-17`). CLAUDE.md prefers pattern matching in heads.

**S2** — `DigestMailer` `to` display name is the email address instead of the user's name (`digest_mailer.ex:12`). Fix: `to({user.name, user.email})`. The test only checks `to_addr` so this defect is invisible currently.

**S3** — No timeout callback on DigestWorker (`digest_worker.ex`). Default is `:infinity`. Add `def timeout(_job), do: :timer.seconds(30)`.

**S4** — `list_high_medium_findings_since/2` has no `LIMIT` — add a cap (~50) with "and N more" trailer in the email body to prevent oversized digests.

**S5** — `List-Unsubscribe` header missing from digest emails — required by Gmail Feb-2024 bulk sender rules and GDPR.

**S6** — `From:` address hardcoded as `noreply@adbutler.app` (`digest_mailer.ex:14`). Move to `Application.fetch_env!`-backed config + `MAILER_FROM_ADDRESS` in `.env.example`.

---

## Clean Areas

- All workers go through context functions — no direct `Repo` calls in workers (Iron Law: PASS)
- All `Analytics` queries use `scope_findings/2` via `Ads.list_ad_account_ids_for_user/1` — no tenant leaks
- SMTP config uses `System.fetch_env!/1` throughout
- Oban queue/cron format correct, Lifeline + Pruner configured
- No `String.to_atom/1` on user input, no bare `raw/1` in templates
- `analytics.ex` DDL identifier interpolations go through `safe_identifier!/1` whitelist
