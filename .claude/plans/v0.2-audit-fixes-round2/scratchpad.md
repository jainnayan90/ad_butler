# Scratchpad — Audit Fixes Round 2

## Key decisions

- `Ads.stream_ad_accounts_and_run/2` added to mirror `Accounts.stream_connections_and_run/2` — this is the clean fix for B1 (Repo in worker) and W4 (publish inside tx) together
- Publishing happens OUTSIDE the Repo.transaction in both scheduler workers — collecting payloads inside tx, publishing after
- `get_7d_insights/1` and `get_30d_baseline/1` renamed to `unsafe_*` (not given a user scope param) — they query materialized views which don't have FK joins to users; scoping would require a subquery join that's expensive. The `unsafe_` prefix + doc note is the chosen pattern (same as `unsafe_get_ad_account_for_sync`).
- W11 (tenant isolation tests for insight views): views are WITH NO DATA in test env — if they can't be populated, tag with @tag :requires_populated_views and skip; don't block on this.
- Partition name derivation: `partition_name/1` uses `ws.year` (not iso_year) for the year component. W13 fix aligns the test helper to use the same derivation logic as the production code (`:calendar.iso_week_number` → `{iso_year, week}`). Check if production `partition_name/1` also needs to use `iso_year` — it uses `ws.year` where `ws` is always the Monday of the week (from `week_start/1`). The ISO year of a Monday is always consistent with the ISO week, so the production code is correct. Only the test helper was using `old_date.year` directly.

## Dead-ends

- Parameterized DDL: PostgreSQL doesn't support `$1` placeholders in DDL (CREATE TABLE). Using `safe_identifier!` + date string from `Date.to_iso8601` (always YYYY-MM-DD) is the correct approach, not positional params.
