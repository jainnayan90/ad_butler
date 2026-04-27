# Iron Law Review

## BLOCKER (violation present)

- **Law 1 (Repo boundary)** — `lib/ad_butler/workers/insights_scheduler_worker.ex:15,20`
  Worker directly aliases `AdButler.Repo` and calls `Repo.transaction(&process_accounts/0, ...)`. Workers must never call `Repo`. The transaction wrapping + streaming should be encapsulated in a context function (e.g. `Ads.run_delivery_scheduler/1`). This is the exact violation ARCH-1 was meant to fix — fixed for Mat/Partition workers but missed for `InsightsSchedulerWorker`.

- **Law 6 (Structured logging)** — `lib/ad_butler_web/controllers/auth_controller.ex:50`
  `Logger.warning("OAuth error from provider (truncated): #{safe_description}")` uses string interpolation. Fix: `Logger.warning("oauth_provider_error", description: safe_description)`

- **Law 6 (Structured logging)** — `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:100` (PRE-EXISTING)
  Mixes interpolation into message string despite having structured keyword args in metadata below.

## WARNING (borderline / risk)

- `lib/ad_butler_web/live/campaigns_live.ex:58`, `ads_live.ex:57`, `ad_sets_live.ex:57` — `handle_params/3` runs `Ads.paginate_*` DB queries on both disconnected (HTTP) and connected (WebSocket) renders. `ConnectionsLive` correctly gates with `if connected?(socket)` inside `handle_params`. The other three LiveViews should do the same to avoid double-querying.

- `lib/ad_butler/analytics.ex:33-43` — `create_future_partitions/0` interpolates `Date.to_iso8601(ws)` values directly into SQL strings. Values come from internal arithmetic (no injection risk today), but `safe_identifier!/1` guard only covers the detach path — inconsistent.

- `lib/ad_butler/sync/insights_pipeline.ex:118` — `{:ok, count} = Ads.bulk_upsert_insights(normalised)` bare-matches the result. If upsert raises (e.g., partition doesn't exist), Broadway will crash the processor. Use `case` and return `Message.failed/2` on `{:error, _}`.

## CLEAN (verified fixed)

- **ARCH-1**: `MatViewRefreshWorker` and `PartitionManagerWorker` correctly delegate to `Analytics` context; no `Repo` in either worker.
- **ARCH-2**: `HealthController` uses `Health.db_ping/0` via configurable fn; no `Repo`/`SQL` in controller.
- **ARCH-4**: Configurable fn pattern correctly applied in both `MatViewRefreshWorker` and `HealthController`.
- **Tenant scoping**: All user-facing `Ads` context queries pass through `scope/2` or `scope_ad_account/2`; `unsafe_*` functions are clearly documented.
- **No `String.to_atom`**: Zero occurrences in `lib/`.
- **LiveView streams**: All five LiveViews use `stream/3`; no plain list assigns for rendered collections.
- **Oban string keys**: Workers pattern-match args with string keys correctly.
- **Broadway context boundary**: `InsightsPipeline` calls only `Ads.*` and `Accounts.*`; no direct `Repo` usage.

## PRE-EXISTING

- `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:100` — structured logging violation exists in a pre-existing file, not introduced by this branch.
