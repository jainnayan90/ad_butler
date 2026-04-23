# Review: Audit Health Fixes (Round 2) — 2026-04-22
**Verdict: REQUIRES CHANGES**
**Issues**: 4 must-fix, 7 warnings, 3 suggestions

Diff: all untracked files + modified tracked files vs main.
Agents: elixir-reviewer, iron-law-judge, security-analyzer, testing-reviewer, oban-specialist.

---

## Must Fix

### MF-1. Nil `ad_set_id` crashes bulk ad insert — NOT NULL violation
`lib/ad_butler/sync/metadata_pipeline.ex:72-73`

`build_ad_attrs/2` sets `ad_set_id: Map.get(ad_set_id_map, a["adset_id"])` which yields `nil` if the ad's parent ad set was absent. `Ad` schema has `ad_set_id` in `@required`; bulk insert with a nil `ad_set_id` violates the NOT NULL constraint and crashes the entire batch — same bug that was fixed for ad sets but not carried to ads. Apply the `Enum.split_with` orphan-guard used for ad sets:

```elixir
attrs_list = Enum.map(ads, &build_ad_attrs(&1, ad_set_id_map))
{valid, orphaned} = Enum.split_with(attrs_list, &(not is_nil(&1.ad_set_id)))
if orphaned != [], do: Logger.warning("Orphaned ads dropped", count: length(orphaned))
Ads.bulk_upsert_ads(ad_account, valid)
```

### MF-2. `Oban.insert_all/1` return discarded in `SyncAllConnectionsWorker`
`lib/ad_butler/workers/sync_all_connections_worker.ex:22`

If the DB is under pressure and insert fails, the worker returns `:ok`, the cron job is marked complete, and the entire sync cycle is silently lost with no retry:

```elixir
case Oban.insert_all(jobs) do
  {:ok, _} -> :ok
  {:error, reason} -> {:error, reason}
end
```

### MF-3. `bulk_upsert_ads/2` has zero tests
`test/ad_butler/ads_test.exs`

New public context function with no `describe "bulk_upsert_ads/2"` block. The pipeline calls it on every sync. Minimum: insert test + idempotency test mirroring `bulk_upsert_ad_sets/2`.

### MF-4. `metadata_pipeline_test.exs` never exercises the ads code path
Every test stubs `list_ads` to `{:ok, []}`. `bulk_upsert_ads/2` is never invoked with real data — schema mismatches and constraint errors in that path are invisible.

---

## Warnings

**W1 — `bulk_upsert_ads/2` result silently discarded** (`metadata_pipeline.ex:73`)
`Logger.info` logs `ads: length(ads)` (raw API count). Bind the result: `{_count, _} = Ads.bulk_upsert_ads(...)` and log the DB-returned count for correctness.

**W2 — `get_ad_account_for_sync/1` public + unscoped (PERSISTENT)** (`lib/ad_butler/ads.ex:50`)
`Repo.get(AdAccount, id)` bypasses tenant scope. Public visibility means future web controllers can call it and bypass tenant isolation. OWASP A01. Fix: move to `AdButler.Ads.Sync` sub-context, or rename `unsafe_get_ad_account_for_sync/1` to make bypass loud in code search.

**W3 — Token-exchange error leaks `code`/token to logs (PERSISTENT, ELEVATED)**
`lib/ad_butler/meta/client.ex:148-149`. `inspect(reason)` propagation confirmed at `fetch_ad_accounts_worker.ex:75,90`, `token_refresh_worker.ex:84`, `metadata_pipeline.ex:91`. With Sentry removed, LoggerJSON is the only sink — impact elevated. Fix at boundary: extract only `code`, `type`, `error_subcode` into a safe struct before returning `{:error, {:token_exchange_failed, safe}}`.

**W4 — `bulk_upsert_*` skips changeset validation on external Meta data**
`lib/ad_butler/ads.ex:79-290`, called from `metadata_pipeline.ex:70-73`. `Campaign.changeset` enforces `validate_inclusion(:status, ~w(ACTIVE PAUSED DELETED ARCHIVED))` — bulk path does not. A new Meta enum value silently persists; nil `name`/`status` crashes the entire batch vs. a filtered skip. Add a `bulk_validate/2` helper that runs each attrs map through the changeset, drops invalid rows with a Logger.warning per `meta_id`.

**W5 — T2/T3/T8 PERSISTENT test issues**
- `replay_dlq_test.exs:70`: `Process.sleep(100)` — timing-dependent.
- `plug_attack_test.exs:44`: `on_exit` restores `:trusted_proxy` to hardcoded `false` instead of capturing original value.
- `AMQPBasicStub`: no `@behaviour AdButler.AMQPBasicBehaviour`.

**W6 — `FetchAdAccountsWorker` doesn't UUID-cast job arg**
`lib/ad_butler/workers/fetch_ad_accounts_worker.ex:19-27`. Malformed string → `Ecto.Query.CastError` → 5 retries → DLQ instead of immediate cancel. Fix: `Ecto.UUID.cast(id)` with `{:cancel, "invalid_meta_connection_id"}` on `:error`.

**W7 — Pool size vs sync queue concurrency**
`config.exs:112`: `queues: [sync: 20]` with default `pool_size: 10` risks DB pool exhaustion at full load. Confirm `POOL_SIZE >= 25` in fly.io secrets.

---

## Suggestions

**S1 — `@doc false` inconsistent with sibling bulk functions**
`bulk_upsert_campaigns/2` and `bulk_upsert_ad_sets/2` use `@doc "Bulk upserts …"`. `bulk_upsert_ads/2` uses `@doc false`. Use the same convention.

**S2 — Partial index for `meta_connections.status`**
Migration is correct. If dominant query is `status = 'active'`, a partial index `WHERE status = 'active'` would be more selective. Acceptable as-is.

**S3 — `account_status` integer from Meta silently cast to string**
`FetchAdAccountsWorker` line 97-107. Meta returns `account_status` as integer; Ecto silently casts to `"1"`. Add a `normalize_account_status/1` mapping and `validate_inclusion` to `AdAccount.changeset/2`.

---

## Prior Findings Resolved

| ID | Status |
|----|--------|
| W1 `get_ad_account/1` IDOR | ✅ Renamed `get_ad_account_for_sync/1` |
| W3 inconsistent `with` else atoms | ✅ Fixed |
| W4 `@spec` too loose for `bulk_upsert_*` | ✅ Fixed — new fn has correct spec |
| W5 `parse_budget` `String.to_integer` | ✅ Replaced with `Integer.parse/1` |
| MF-1 `SyncAllConnectionsWorker` Enum.each | ✅ Switched to `Oban.insert_all` |
| S2 `FetchAdAccountsWorker` missing `timeout/1` | ✅ `timeout(_job), do: :timer.minutes(5)` |
| T4 idempotency test no readback | ✅ Fixed |
| T7 `list_ads/2` filter opts untested | ✅ Added |

## Iron Law Note

Iron Law Judge flagged `{:snooze, {15, :minutes}}` as Oban Pro syntax. **Superseded by Oban Specialist verification**: `deps/oban/lib/oban/period.ex` confirms `Oban.Period` ships with standard Oban 2.20+; the tuple syntax is valid in 2.21.x. No change needed.
