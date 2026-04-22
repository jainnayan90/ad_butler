# Scratchpad: Week 1 Review Fixes

## Source
Triage of review findings from `week-1-days-2-to-5` sprint.
All 28 findings approved for fixing. No custom guidance — use exact fixes from review.

## Key Decisions

### Phase ordering rationale
1. **Security first** (auth_controller.ex) — B5/B6 are session fixation + timing attack; highest exploitability
2. **Oban worker** — B1/B7 are correctness issues that could silently corrupt state in prod; independent of other phases
3. **Data & client layer** — B2/B3 fix PII leak + account takeover; W5/S7-S9 are cleanup in same files
4. **Config & infrastructure** — W4/W6/W8/S1 touch multiple files; do after logic is stable
5. **Tests last** — B4/W9/W10/S2-S6 depend on correct implementations above

### W6 dependency note
Moving `exchange_code_for_token` and `fetch_user_info` from AuthController to Meta.Client (W6) affects:
- `auth_controller.ex` (callers)
- `meta/client.ex` (implementation)
- `auth_controller_test.exs` (stubs may change)
Do W6 in Phase 4 after auth_controller security fixes (Phase 1) are stable.

### B2 (ETS wrong key) — thread ad_account_id
`parse_rate_limit_header/2` signature changes from `(resp, access_token)` to `(resp, ad_account_id)`.
Callers: `list_ad_accounts/1` and any other calls in client.ex. Check all call sites.

### B3 (upsert conflict target) — migration may be needed
Changing `conflict_target: :email` to `conflict_target: :meta_user_id` in accounts.ex requires
`meta_user_id` to have a unique index. Verify the existing migration has `unique_index(:users, [:meta_user_id])`.
If not, generate a new migration.

### W1 (permanent vs transient errors) + W2 (get_meta_connection/1)
Both are in `token_refresh_worker.ex` and handled together in Phase 2.
W1 requires adding `:revoked` to valid statuses in `meta_connection.ex` changeset — cross-phase dependency.
Add `:revoked` to `validate_inclusion` in meta_connection.ex as part of Phase 2.

## Dead Ends
(none yet)
