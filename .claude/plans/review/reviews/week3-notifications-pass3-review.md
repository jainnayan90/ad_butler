# Code Review (Pass 3): Week 3 — Notifications + Digest Workers

**Date:** 2026-04-29
**Prior reviews:** pass1 (15 findings), pass2 (1 blocker + 4 warnings) — all resolved
**Agents:** elixir-reviewer · iron-law-judge · security-analyzer · testing-reviewer · oban-specialist

---

## Verdict: REQUIRES CHANGES

**2 Blockers · 8 Warnings · 7 Suggestions**

---

## Prior Findings — All Fixed ✓

All pass-1 and pass-2 findings confirmed resolved, including HTML injection, header injection, Oban unique constraints, {:cancel} for missing user, Mailer.deliver pattern match, cross-tenant test, insert_all dead code, cron string keys, logger metadata keys.

---

## BLOCKERS

### B1 — `DigestWorker.perform/1` missing `{:error, reason}` clause
**`lib/ad_butler/workers/digest_worker.ex:18-21`**
*(flagged by: elixir-reviewer · iron-law-judge · oban-specialist · testing-reviewer — deduplicated)*

`Notifications.deliver_digest/2` is spec'd as `:ok | {:skip, :no_findings} | {:error, term()}`. The inner `case` only matches the first two arms. An SMTP failure raises `CaseClauseError`, which Oban catches and retries — mechanically the retries happen, but the logged error is `CaseClauseError` instead of the real SMTP reason, making on-call debugging unnecessarily hard. CLAUDE.md requires every `{:error, reason}` to be explicitly propagated or logged.

```elixir
case Notifications.deliver_digest(user, period) do
  :ok                   -> :ok
  {:skip, :no_findings} -> :ok
  {:error, reason}      -> {:error, reason}
end
```

A test for the SMTP-failure path is also missing — see S3 below.

---

### B2 — `DigestMailer.build/4` total_count overflow branch never exercised
**`test/ad_butler/notifications/digest_mailer_test.exs`**
*(flagged by: testing-reviewer — was S1 in Pass 2, not addressed)*

`DigestMailer.build/4` has `total_count \\ nil`. When `total_count > length(findings)`, both `build_text_body/3` and `build_html_body/3` emit an overflow trailer. Every test uses the 3-arity form — both overflow branches are permanently dead in tests.

Fix: add a test using `build(user, findings, "daily", 10)` with 2 findings and assert `"and 8 more findings"` in both `text_body` and `html_body`.

---

## WARNINGS

### W1 — `period` not validated in `DigestWorker.perform/1` — defense-in-depth gap
**`lib/ad_butler/workers/digest_worker.ex:12`**
*(flagged by: security-analyzer)*

`DigestMailer.build/4` guards `period in ["daily", "weekly"]`. But `DigestWorker.perform/1` passes `args["period"]` straight to `deliver_digest/2` without revalidation. A DB-compromise scenario inserting a forged Oban job with a crafted `period` value would reach `DigestMailer.build/4` guarded by `FunctionClauseError` (crashes, retries) rather than returning `{:cancel, "invalid period"}`. Add a guard clause:

```elixir
def perform(%Oban.Job{args: %{"user_id" => user_id, "period" => period}})
    when period in ["daily", "weekly"] do
  ...
end

def perform(%Oban.Job{args: args}),
  do: {:cancel, "invalid period: #{inspect(Map.get(args, "period"))}"}
```

---

### W2 — `safe_display_name/1` returns `""` for all-CRLF input — truthy in Elixir
**`lib/ad_butler/notifications/digest_mailer.ex:11, 30`**
*(flagged by: security-analyzer)*

After stripping `\r\n\0`, an all-CRLF name becomes `""`. In Elixir, `""` is truthy, so `"" || user.email` evaluates to `""`. Swoosh receives `{"", user.email}` instead of falling back to the email address as display name.

Fix: return `nil` when the stripped result is blank:
```elixir
defp safe_display_name(name) do
  stripped = name |> String.replace(~r/[\r\n\0]/, "") |> String.slice(0, 100)
  if stripped == "", do: nil, else: stripped
end
```

---

### W3 — `DigestMailer.build/4` missing `@spec`
**`lib/ad_butler/notifications/digest_mailer.ex:7`**
*(flagged by: elixir-reviewer)*

Has `@doc` but no `@spec`. CLAUDE.md requires `@spec` for every public `def`.

```elixir
@spec build(User.t(), [Finding.t()], String.t(), non_neg_integer() | nil) :: Swoosh.Email.t()
```

---

### W4 — `SMTP_PORT` parsed with bare `String.to_integer/1`
**`config/runtime.exs` (SMTP port line)**
*(flagged by: elixir-reviewer)*

Raises a generic `ArgumentError` on a bad env value (e.g. trailing space `"587 "`). The project already uses `Integer.parse/1` with an explicit error message for `RABBITMQ_POOL_SIZE`. Apply the same pattern here for consistent boot-time errors.

---

### W5 — `timeout/1` of 30s may be tight for SMTP
**`lib/ad_butler/workers/digest_worker.ex:26`**
*(flagged by: oban-specialist)*

30s is plausible but can be too short on cold-start TLS handshakes under load. Timed-out jobs sit in `executing` state for up to Lifeline's rescue window. Consider `:timer.seconds(60)` or removing the override and relying on the SMTP adapter's socket timeout.

---

### W6 — Daily and weekly cron both fire at 08:00 on Mondays
**`config/config.exs` (cron schedules)**
*(flagged by: oban-specialist)*

`"0 8 * * *"` (daily) and `"0 8 * * 1"` (weekly) overlap every Monday. Unique constraint correctly distinguishes them by args, so both fan-outs proceed — users receive two digests on Mondays. If only the weekly digest is intended on Mondays, change daily cron to `"0 8 * * 2-7"`.

---

### W7 — "no active connections" test missing empty-queue assertion
**`test/ad_butler/workers/digest_scheduler_worker_test.exs:39`**
*(flagged by: testing-reviewer — was in Pass 2, not fixed)*

Only `:ok` return is checked. A bug enqueuing stale jobs would pass silently.

Fix: add `assert all_enqueued(worker: DigestWorker) == []`.

---

### W8 — `user_without_findings/0` and `user_with_finding/1` duplicated verbatim
**`test/ad_butler/notifications/notifications_test.exs:9-24` vs `test/ad_butler/workers/digest_worker_test.exs:10-25`**
*(flagged by: testing-reviewer — was S3 in Pass 2, not fixed)*

Identical private helpers in two files. A schema change requires editing both.

Fix: extract to `test/support/notifications_fixtures.ex`.

---

## SUGGESTIONS

**S1** — CRLF header-injection guard in `safe_display_name/1` untested. Add: `name: "Bad\r\nActor"`, assert `\r`/`\n` absent from `email.to` display name.

**S2** — 100-char truncation in `safe_display_name/1` untested. Add test with >100-char name.

**S3** — Missing test for `{:error, reason}` path in `DigestWorker.perform/1`. Mox-stub `Mailer.deliver` to return `{:error, :timeout}`, assert job returns `{:error, :timeout}`.

**S4** — Fan-out test should assert exact count: `assert length(all_enqueued(worker: DigestWorker)) == 2` (currently checks each user individually but not total).

**S5** — `deliver_digest/2` uses `if findings == []` — prefer multi-clause function heads per CLAUDE.md ("Pattern-match in function heads, not in case blocks inside the body").

**S6** — `list_users_with_active_connections/0` loads full User structs (including Cloak-encrypted fields) when `DigestSchedulerWorker` only uses `.id`. A slimmed query returning `[binary()]` would avoid unnecessary decryption at scale.

**S7** — SMTP error reason from `Mailer.deliver/1` may contain recipient address in `RCPT TO:` failure strings; Oban logs this bypassing `:filter_parameters`. Consider `{:error, :delivery_failed}` with structured logging of the reason via `AdButler.Log.redact/1`.

---

## Clean Areas

- Tenant isolation: `scope_findings/2` pins ad_account_ids to user — no cross-tenant leak
- Oban job forgery: recipient derives from DB lookup, not job args — attacker cannot redirect mail
- Email HTML escaping: `f.title` via `h/1`; `f.severity` safe (DB-constrained)
- SMTP TLS: `verify_peer` + `cacerts_get` + SNI + `depth: 3` — correct
- Header injection: `safe_display_name/1` strips `\r\n\0`, slices to 100
- filter_parameters: email, smtp_password, smtp_username added
- Oban unique constraints: 25h on DigestWorker, 23h on DigestSchedulerWorker — both correct
- Cron args string keys: confirmed
- {:cancel, "user not found"}: correct OSS Oban permanent-failure return
