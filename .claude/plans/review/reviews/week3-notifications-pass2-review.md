# Code Review (Pass 2): Week 3 — Notifications + Digest Workers

**Date:** 2026-04-29
**Prior review:** `week3-notifications-review.md` — 3 Blockers, 9 Warnings resolved in triage
**Agents:** elixir-reviewer · oban-specialist · security-analyzer · testing-reviewer

---

## Verdict: REQUIRES CHANGES

**1 Blocker · 4 Warnings · 5 Suggestions**

---

## Prior Findings — All Fixed ✓

B1 HTML injection, B2 unique constraint, B3 atom keys, W1 get_user!, W2 tenant isolation test, W3 direct test coverage, W4 assert_enqueued period key, W5 scheduler dedup, W7 SMTP TLS, W8 filter_parameters, W9 chunking, S2 display name, S3 timeout, S4 finding limit, S5 List-Unsubscribe — all confirmed resolved.

---

## BLOCKER

### B1 — `Oban.insert_all` failure detection is dead code
**`lib/ad_butler/workers/digest_scheduler_worker.ex:25`**
*(flagged by: elixir-reviewer + oban-specialist — deduplicated)*

The W6 fix (`Enum.count(results, &match?(%Ecto.Changeset{}, &1))`) looks correct but is non-functional. `Oban.insert_all/1` spec is `[Job.t()]` — it only returns successfully inserted job structs. Jobs skipped by the uniqueness constraint are simply absent from the list. Invalid changesets raise `Ecto.InvalidChangesetError` before the DB call — they never appear in results. `failed` is always `0`, the warning never fires.

```elixir
# Fix: detect missing inserts by counting
inserted = length(results)
expected = length(chunk)

if inserted < expected do
  Logger.warning("DigestSchedulerWorker: some digest jobs not enqueued",
    inserted: inserted,
    expected: expected,
    period: period
  )
end
```

Note: during the 25h unique window, `inserted < expected` is expected behaviour (duplicate suppression). Log at `:debug` instead of `:warning` if that's noise — or track `inserted == 0 and expected > 0`.

---

## WARNINGS

### W1 — `Mailer.deliver/1` return silently discarded
**`lib/ad_butler/notifications.ex:22`**
*(flagged by: elixir-reviewer + oban-specialist — deduplicated)*

`Swoosh.Mailer.deliver/2` returns `{:ok, _} | {:error, reason}`. The current code calls `Mailer.deliver(email)` and returns `:ok` unconditionally. A transient SMTP error marks the Oban job succeeded — no retry ever occurs. Fix:

```elixir
case Mailer.deliver(email) do
  {:ok, _} -> :ok
  {:error, reason} -> {:error, reason}
end
```

### W2 — Email header injection via `user.name` (NEW)
**`lib/ad_butler/notifications/digest_mailer.ex:10-13`**
*(flagged by: security-analyzer)*

`user.name` comes from the Meta Graph API. `User.changeset/2` validates email and `meta_user_id` formats but not `name`. A name containing `\r\n` enables RFC 5322 header injection — an attacker-controlled Meta account name could inject arbitrary SMTP headers.

```elixir
defp safe_display_name(nil), do: nil
defp safe_display_name(name),
  do: name |> String.replace(~r/[\r\n\0]/, "") |> String.slice(0, 100)

display_name = safe_display_name(user.name) || user.email
```

### W3 — Cross-tenant test is one-sided proof
**`test/ad_butler/notifications/notifications_test.exs:66`**
*(flagged by: testing-reviewer)*

The test asserts user B gets `{:skip, :no_findings}` but never confirms user A's data would actually produce an email. If a time-window bug silently excluded all findings, the test would pass for the wrong reason.

```elixir
test "does not deliver another user's findings" do
  user_a = user_with_finding("high")
  user_b = user_without_findings()

  # First prove user A's data is reachable
  assert :ok = Notifications.deliver_digest(user_a, "daily")
  assert_email_sent(...)

  # Then prove isolation
  Swoosh.Adapters.Local.Storage.Memory.delete_all()
  assert {:skip, :no_findings} = Notifications.deliver_digest(user_b, "daily")
  assert_no_email_sent()
end
```

### W4 — `period` unescaped in DigestMailer HTML/text (RESIDUAL — low risk)
**`lib/ad_butler/notifications/digest_mailer.ex:9,33,63`**
*(flagged by: security-analyzer)*

`period` is interpolated raw into the subject, text header, and `<h2>` tag. Today it is constrained to `"daily" | "weekly"` upstream, but `DigestMailer.build/4` doesn't enforce that contract. A future caller passing arbitrary input would inject HTML. Add a guard:

```elixir
def build(user, findings, period, total_count \\ nil)
    when period in ["daily", "weekly"] do
```

---

## SUGGESTIONS

**S1** — `h/1` on `f.severity` is redundant (`digest_mailer.ex:51`). Severity is DB-constrained to "high"/"medium". Removing `h(String.upcase(f.severity))` → `String.upcase(f.severity)` makes the escaping intent clearer.

**S2** — `total_count` overflow trailer untested. Add: `DigestMailer.build(user, [finding], "daily", 10)` → assert `text_body =~ "and 9 more"`.

**S3** — `user_without_findings/0` duplicated verbatim in `notifications_test.exs` and `digest_worker_test.exs`. Extract to `test/support/notification_helpers.ex` or `factory.ex`.

**S4** — Bind `smtp_host` once in `runtime.exs` — `System.fetch_env!("SMTP_HOST")` appears on lines 178 and 187. Prevents silent divergence on future edits.

**S5** — Add `List-Unsubscribe-Post: List-Unsubscribe=One-Click` before scaling beyond design partners (Gmail Feb-2024 requirement for >5k/day senders).

---

## Clean Areas

- All 13 prior BLOCKERs/WARNINGs confirmed resolved
- Unique constraint implementation verified correct against Oban source
- `{:cancel, "user not found"}` — correct OSS Oban permanent-failure return
- `@impl Oban.Worker` on `timeout/1` — correct, callback declared in Oban.Worker
- SMTP TLS: `verify_peer` + `cacerts_get` + SNI + `depth: 3` — correct
- filter_parameters additions — correct
- Tenant isolation in Analytics queries — unchanged, clean
