# Elixir Review — week-01-Day-01-05-Data-Foundation-and-Ingestion

## BLOCKER

- **lib/ad_butler/analytics.ex:33-44** — SQL built with string interpolation of date literals. `Date.to_iso8601(ws)` and `Date.to_iso8601(we)` are interpolated directly into `CREATE TABLE ... FOR VALUES FROM ('#{...}') TO ('#{...}')`. Use `Repo.query!/3` with positional params ($1, $2). The name is guarded by `safe_identifier!` but the date values are not.

- **lib/ad_butler/sync/insights_pipeline.ex:118** — Bare pattern match `{:ok, count} = Ads.bulk_upsert_insights(normalised)` inside `fetch_and_upsert/4`. If `Repo.insert_all` raises (constraint, network), the Broadway processor crashes without calling `Message.failed/2`. Use `case` and return `{:error, reason}` on failure.

- **lib/ad_butler/workers/insights_scheduler_worker.ex:37** — `errors ++ chunk_errors` inside `Enum.reduce` over potentially thousands of ad accounts is O(n²) list concatenation. Accumulate with `[chunk_errors | errors]` and flatten once at the end.

## WARNING

- **lib/ad_butler/ads.ex:556** — `@spec bulk_upsert_insights([map()]) :: {:ok, non_neg_integer()}` is missing `| {:error, term()}`. The `@doc` explicitly says "Returns `{:ok, count}` on success or `{:error, term()}` on failure" but the spec only declares success.

- **lib/ad_butler/ads.ex:593,620** — `import Ecto.Query` appears inside both `get_7d_insights/1` and `get_30d_baseline/1` function bodies, but the module already has `import Ecto.Query` at line 9. Remove the redundant inner imports.

- **lib/ad_butler/workers/insights_conversion_worker.ex:18** — `Ads.list_ad_accounts_internal()` loads all active ad accounts into a list. PERF-2 added `stream_active_ad_accounts/0` for this use case and updated `InsightsSchedulerWorker`. `InsightsConversionWorker` was left on the non-streaming path.

- **lib/ad_butler/workers/insights_scheduler_worker.ex:20** — External side-effects (RabbitMQ `publisher().publish/1`) execute inside `Repo.transaction/2`. A DB error will abort publishes mid-way, and messages published before the abort are not rolled back. Stream + collect account IDs in the transaction, then publish outside it.

- **lib/ad_butler/meta/client.ex:229,232** — `acc ++ data` in recursive `fetch_all_pages/6` is O(n²) per page. Prepend `data` and reverse once: `[data | acc]` accumulated, then `Enum.concat(Enum.reverse(acc))` at the base case.

- **priv/repo/migrations/20260426100002_create_insights_initial_partitions.exs:32-34** — `down` only drops the PL/pgSQL function, not the four partitions created by calling it. Rollback leaves orphan partitions that block re-running `up`.

- **lib/ad_butler/analytics.ex:87** — `REFRESH MATERIALIZED VIEW CONCURRENTLY #{view_name}` interpolates `view_name` directly. Apply the same `safe_identifier!` guard used in `maybe_detach_partition/2` for consistency.

- **lib/ad_butler/sync/insights_pipeline.ex:88** — `meta_client()` (`Application.get_env`) called once per message inside `Enum.map` in `handle_batch/4`. Call it once at the top of `handle_batch/4` and thread the value through.

- **lib/ad_butler/ads.ex:591-640** — `get_7d_insights/1` and `get_30d_baseline/1` query by `ad_id` without any user/tenant scope. Either accept a `user` param and join through `AdAccount`, or add an `unsafe_` prefix and document that callers must verify ownership.

## SUGGESTION

- **lib/ad_butler/sync/insights_pipeline.ex:113-117** — `Enum.filter` + `Enum.map` can be a single `for` comprehension.

- **lib/ad_butler/workers/mat_view_refresh_worker.ex:15** — `refresh_fn().(period)` calls an anonymous function from `Application.get_env`. A misconfigured env produces a cryptic `BadFunctionError`. Add a `@spec` for `refresh_fn/0`.

- **lib/ad_butler/ads.ex:62** — `length(rows) == 200` traverses the full list. Since the query already does `limit(200)`, this is redundant but harmless.

## PRE-EXISTING (unchanged code, not in scope)

- **lib/ad_butler_web/live/campaigns_live.ex:58** — `Ads.paginate_campaigns` runs in `handle_params` without a `connected?` guard, hitting the DB on every disconnected render. Pre-existing pattern across all LiveViews.
- **lib/ad_butler_web/controllers/auth_controller.ex:50** — `Logger.warning` uses string interpolation for the OAuth provider error description. Pre-existing (same file as SEC-2 fix but different callback).
- **lib/ad_butler/accounts.ex:135** — `length(rows) > limit` O(n) check on already-fetched list. Pre-existing.
