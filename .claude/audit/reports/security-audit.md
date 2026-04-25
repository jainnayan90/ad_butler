# Security Audit
Date: 2026-04-25

## Score: 88/100

## Issues Found

### [HIGH] Meta Graph API access tokens in GET query strings
`lib/ad_butler/meta/client.ex:21-72`

All GET calls (list_ad_accounts, list_campaigns, list_ad_sets, list_ads, get_creative, get_me)
pass access_token via params: (URL query string). Tokens are visible in Fly router logs, Meta
server access logs, and any TLS-terminating proxy. exchange_code/1 and refresh_token/1 correctly
use POST form bodies.
Fix: use headers: [{"authorization", "Bearer " <> access_token}] on all GET calls.
Deduction: -5 pts

### [MEDIUM] OAuth callback rate limit too coarse
`lib/ad_butler_web/plugs/plug_attack.ex:18-26`

Single 10 req/60s throttle covers all /auth/* routes. The callback path triggers a Meta
token-exchange + DB write — 10/min is too permissive.
Fix: Add dedicated rule for /auth/meta/callback at 3/min.
Deduction: -5 pts

### [LOW] Dev Cloak key defaults to all-zeros base64
`config/dev.exs:106-112`

Fallback "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" encrypts with a known zero key
when CLOAK_KEY_DEV is unset. Safe on isolated laptops, dangerous if dev data is ever shared.
Fix: Remove the default; raise if CLOAK_KEY_DEV is unset.
Deduction: -2 pts

### [INFO] `dev_routes` guard is implicit
`lib/ad_butler_web/router.ex:83`

LiveDashboard + Swoosh mailbox behind compile_env(:ad_butler, :dev_routes). A future
config :ad_butler, dev_routes: true in prod would expose both.
Fix: Add && config_env() == :dev to the guard. No deduction (compile-time guard exists).

## Clean Areas
No String.to_atom with user input. No raw() calls. No SQL fragment string interpolation.
All LiveViews behind live_session :authenticated with on_mount + RequireAuthenticated plug.
All queries scope through meta_connection_id in ^mc_ids. Production secrets exclusively
from env vars in runtime.exs. Strict CSP. CSRF active. OAuth state uses secure_compare + TTL.

## Score Breakdown

| Criterion | Score | Max | Notes |
|-----------|-------|-----|-------|
| No sobelow critical issues | 30 | 30 | Clean |
| No sobelow high issues | 15 | 20 | [HIGH] access tokens in GET query string |
| Authorization in all handle_events | 15 | 15 | Full coverage via on_mount + plug + query scoping |
| No String.to_atom with user input | 10 | 10 | None found |
| No raw() with untrusted content | 10 | 10 | None found |
| Secrets in runtime.exs only | 8 | 15 | Prod correct; dev zero-key -2; auth rate-limit gap -5 |
