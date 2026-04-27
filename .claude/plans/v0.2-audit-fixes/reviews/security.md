# Security Review

## BLOCKER
(none)

## WARNING

- **lib/ad_butler/analytics.ex:33-37** — `create_future_partitions/0` interpolates `pname` and ISO date strings directly into `CREATE TABLE` DDL via `Repo.query!`. `safe_identifier!/1` whitelist exists in this module but is NOT applied to `pname` here — only on `relname` inside `maybe_detach_partition/2`. Currently `partition_name/1` only joins integers (no injection risk today), but this is a defense-in-depth gap. Apply `safe_identifier!/1` to `pname` or port to `format(... %I, %L)` PL/pgSQL pattern.

- **lib/ad_butler/analytics.ex:84-87** — `do_refresh/1` interpolates `view_name` into `REFRESH MATERIALIZED VIEW CONCURRENTLY #{view_name}`. The two callers pass hardcoded literals (safe today), but the helper itself accepts any string. Apply `safe_identifier!/1` or inline per-clause.

- **lib/ad_butler/analytics.ex:18-20** — `refresh_view/1` fallback echoes the user-supplied `view` value in the error string. Prefer `{:error, :unknown_view}`.

- **config/runtime.exs:35-39** — Cloak prod key validation checks size (32 bytes) but does NOT check for the all-zeros placeholder used in dev.exs. If `CLOAK_KEY` is misconfigured to that placeholder in prod, the app boots with a known-zero key. Add the same `cloak_key == <<0::256>>` raise that the `:dev` block has.

- **lib/ad_butler_web/controllers/auth_controller.ex:50** — Logger uses string interpolation (`"OAuth error from provider (truncated): #{safe_description}"`) rather than the structured key-value form required by CLAUDE.md. Switch to `Logger.warning("oauth_provider_error", description: safe_description)`.

- **lib/ad_butler_web/controllers/auth_controller.ex:54** — same OAuth error description is rendered to the user via `put_flash`. Meta error text is flashed from a third-party provider. Prefer a generic flash and log the provider description only.

## SUGGESTION

- **lib/ad_butler/ads.ex:107-122** — `unsafe_*` and internal functions bypass tenant scoping. The `unsafe_` prefix helps; consider moving to an `Ads.Internal` module so they cannot be accidentally reached.

- **config/dev.exs:127** — all-zeros placeholder `"AAAA..."` as default for `CLOAK_KEY_DEV` is safe because runtime.exs raises before boot. Add a comment warning that data encrypted with this key has zero secrecy.

- **lib/ad_butler_web/live/ad_sets_live.ex:80-89** (and `ads_live.ex`, `campaigns_live.ex`) — `ad_account_id` is not validated as a UUID format before being put into URL/query. Currently safe via scope join yielding empty results for wrong-tenant IDs, but UUID format validation up front would be a small hardening win.

- Tenant isolation in new LiveViews verified: every `paginate_*` call routes through `current_user` → resolves `mc_ids` → `scope/2`. Good.

## PRE-EXISTING

- **lib/ad_butler_web/live/ad_sets_live.ex:206** — `:erlang.float_to_binary(cents / 100.0, ...)` violates "NEVER use :float for money" in display only. Predates this branch.
- **lib/ad_butler/sync/metadata_pipeline.ex:51** — `unsafe_get_ad_account_for_sync` same pattern as insights pipeline. Predates this branch.
