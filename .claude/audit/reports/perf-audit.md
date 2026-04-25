# Performance Audit
Date: 2026-04-25

## Score: 72/100

## Issues Found

### 1. [FUNCTIONAL BUG] `@ad_accounts_list` never loaded — filter dropdown always empty on page load
`lib/ad_butler_web/live/campaigns_live.ex:39-61`

`handle_params/3` loads campaigns but never populates `:ad_accounts_list`. The filter
`<select>` iterates `@ad_accounts_list`, which remains `[]` on initial load and every
filter navigation. Ad accounts only become visible after a WebSocket reconnect fires
`handle_info(:reload_on_reconnect)`. Root cause: the B2 connected?(socket) fix emptied
mount but handle_params was not updated to provide the ad account list.

Fix: Populate ad_accounts_list in handle_params/3 (or send :load_ad_accounts in connected
mount and handle it separately from the campaign reload).

### 2. Double `list_meta_connection_ids_for_user` on reconnect
`lib/ad_butler_web/live/campaigns_live.ex:181-192`

`handle_info(:reload_on_reconnect)` calls `Ads.list_campaigns` then `Ads.list_ad_accounts`
sequentially. Each fires an independent `SELECT mc.id FROM meta_connections WHERE user_id = ?`.
Fix: resolve mc_ids once and pass both calls the mc_ids-arity variants.

### 3. Missing composite index on `meta_connections(user_id, status)`
`lib/ad_butler/accounts.ex:168-172`

Hot path called once per request for every Ads list function. Only single-column user_id
and status indexes exist. A composite (user_id, status) index gives a tighter scan.

### 4. Missing status index on `ads` table
Campaigns and ad_sets have composite (ad_account_id, status) indexes from migration
20260423000000; ads table was skipped. Status-filtered ad queries fall back to a full
scan on the ad_account_id index result.

### 5. `@ad_accounts_list` plain assign duplicates stream on every socket diff
`lib/ad_butler_web/live/campaigns_live.ex:33,194`

`assign(:ad_accounts_list, ad_accounts)` stores the full list alongside the stream.
The plain assign is serialized into every LiveView diff push.
Fix: use temporary_assigns or drop one of the two representations.

### 6. `list_ad_accounts/1` and `list_campaigns/2` load `raw_jsonb` unnecessarily
`lib/ad_butler/ads.ex:48-52`, `lib/ad_butler/ads.ex:145-150`

No select: clause fetches the raw_jsonb JSONB blob for every row even though LiveViews
only render id, name, currency, timezone_name, status, objective.

## Clean Areas
Broadway handle_batch pre-fetches all MetaConnections in a single WHERE IN query.
do_bulk_upsert is a single insert_all per entity type. Both LiveViews use stream/3
for primary list rendering. Publisher pool uses atomics round-robin — no bottleneck.

## Score Breakdown

| Criterion | Score | Max | Notes |
|-----------|-------|-----|-------|
| No N+1 patterns | 20 | 30 | -5 double mc_ids on reconnect; -5 handle_params missing ad_accounts load |
| Indexes for common queries | 10 | 20 | -5 missing composite (user_id, status); -5 missing ads status index |
| Preloads used appropriately | 15 | 15 | No lazy-preload or N+1 via associations |
| No GenServer bottlenecks | 15 | 15 | Publisher pool + atomics; ETS for RateLimitStore |
| LiveView streams for large lists | 5 | 10 | -5 ad_accounts_list plain assign duplicates stream |
| Queries avoid SELECT * | 7 | 10 | -2 list_ad_accounts raw_jsonb; -1 list_campaigns raw_jsonb |
