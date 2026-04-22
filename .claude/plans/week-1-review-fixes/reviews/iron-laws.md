# Iron Law Violations: Week 1 Auth + Oban Review-Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write access unavailable)

Files scanned: auth_controller.ex, token_refresh_worker.ex, application.ex, accounts.ex, meta/client.ex, accounts/meta_connection.ex + config files
Violations: 3 (0 critical, 1 high, 2 medium)

## High

**[Unbounded ETS Table] No TTL/Pruning Strategy** (`lib/ad_butler/meta/rate_limit_store.ex:4-13`)
ETS table created with no eviction. The file acknowledges: `# ETS table entries are never pruned; add a periodic cleanup if cardinality grows unbounded.` Confidence: REVIEW
Fix: Add `Process.send_after(self(), :cleanup, @ttl_ms)` in `init/1` and a `handle_info(:cleanup, state)` using `:ets.select_delete/2` with a match spec on stale timestamps.

## Medium

**[Input Validation] OAuth `code` Parameter Not Validated** (`auth_controller.ex:38-53`)
`code` is passed directly to `Client.exchange_code/3` with no length or format check. The `state` is validated via `secure_compare` but `code` is not. Confidence: REVIEW
Fix: Add size guard before `with` chain (`String.length(code) > 512`).

**[Missing Upsert] `create_meta_connection/2` Errors on Re-authentication** (`accounts.ex:32-36`)
`Repo.insert()` with no `on_conflict`. A re-authenticating user hits `unique_constraint([:user_id, :meta_user_id])` and falls through to generic auth error. Confidence: LIKELY
Fix: mirror `create_or_update_user/1` pattern with `on_conflict: {:replace, [...]}, conflict_target: [:user_id, :meta_user_id]`.

## Clean Checks (13 passing)
- No `String.to_atom/1` with user input
- No `raw/1` with untrusted content
- All Ecto `where` clauses use `^` pinning
- No hardcoded secrets (test key in test.exs is acceptable)
- No `:float` for money
- Oban worker uses string keys
- Oban args contain only binary ID
- Oban unique constraint declared
- No snooze+attempt infinite loop
- All Repo calls inside `AdButler.Accounts` context module
- `RateLimitStore` GenServer owns ETS table (valid isolation)
- No implicit cross joins
- No SQL fragment interpolation
