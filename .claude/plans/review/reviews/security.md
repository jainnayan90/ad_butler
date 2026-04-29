## Security Audit — Pass 3

**No Critical issues. 1 Medium · 4 Low. Major prior issues all fixed.**

---

## MEDIUM

**1. `period` interpolated unescaped into email subject, text, and HTML body**
`lib/ad_butler/notifications/digest_mailer.ex:10, 40, 70`

Public `build/4` guards `period in ["daily", "weekly"]`. But `DigestWorker.perform/1` (`digest_worker.ex:12`) passes `args["period"]` straight through without re-validating. A forged Oban job (DB-compromise scenario) lets attacker-controlled HTML/CRLF reach `subject/1` and HTML body.

Fix: Add `when period in ["daily", "weekly"]` guard to `DigestWorker.perform/1` with `{:cancel, "invalid period"}` fallback.

---

## LOW

**2. `safe_display_name/1` returns `""` for all-CRLF input — truthy in Elixir**
`lib/ad_butler/notifications/digest_mailer.ex:11, 30`

After stripping CRLF, `""` is truthy in Elixir → `"" || user.email` evaluates to `""` → Swoosh receives `{"", user.email}` instead of falling back to email address.

Fix: `if result == "", do: nil, else: result` (or `Enum.empty?`).

**3. List-Unsubscribe non-actionable — no per-user token, no One-Click header**
`lib/ad_butler/notifications/digest_mailer.ex:17`

Hardcoded `<mailto:unsubscribe@adbutler.app>` fails Gmail/Yahoo bulk-sender requirements (Feb 2024 mandate for >5k/day) and is spoofable without a signed token. Add signed token + `List-Unsubscribe-Post: List-Unsubscribe=One-Click` before scaling.

**4. SMTP error reason may leak recipient email to Oban error logs**
`lib/ad_butler/notifications.ex:25-28`

`{:error, reason}` propagated to Oban; SMTP `RCPT TO:` failure strings often contain the recipient address. Oban failure logging bypasses `:filter_parameters`. Fix: redact via `AdButler.Log.redact/1` and return `{:error, :delivery_failed}`.

**5. TLS hardening: missing explicit versions and hostname match fun**
`config/runtime.exs` (SMTP TLS config)

Correct: `verify_peer`, `cacerts_get()`, SNI, `depth: 3`. Missing: `versions: [:"tlsv1.2", :"tlsv1.3"]` and `customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]`.

---

## Verified Clean

- Tenant isolation: `scope_findings/2` filters by `ad_account_id in ^list_ad_account_ids_for_user(user)` — no cross-tenant leak
- Oban job forgery: recipient email derives from DB lookup of user_id, not from job args
- Email content escaping: `f.title` via `h/1`; `f.severity` safe (DB-constrained)
- Header injection: `safe_display_name/1` strips `\r\n\0`, slices to 100 chars
- filter_parameters: email, smtp_password, smtp_username added
- Logger metadata: only user_id, period, chunk_size — no PII
