# Triage: Audit Health Fixes (Round 2) — 2026-04-22
**Decision: Fix everything — all 4 must-fix + all 7 warnings**

---

## Fix Queue

### Must Fix
- [ ] MF-1: `metadata_pipeline.ex:72` — filter nil `ad_set_id` before `bulk_upsert_ads` (Enum.split_with orphan guard, same as ad_sets)
- [ ] MF-2: `sync_all_connections_worker.ex:22` — handle `Oban.insert_all/1` return value (`{:ok, _} → :ok`, `{:error, r} → {:error, r}`)
- [ ] MF-3: `test/ad_butler/ads_test.exs` — add `describe "bulk_upsert_ads/2"` with insert + idempotency tests
- [ ] MF-4: `test/ad_butler/sync/metadata_pipeline_test.exs` — add test with non-empty ads list to exercise bulk_upsert_ads path

### Warnings
- [ ] W1: `metadata_pipeline.ex:73` — bind `{_count, _} = Ads.bulk_upsert_ads(...)`, log DB count not API count
- [ ] W2: `ads.ex:50` — rename `get_ad_account_for_sync/1` → `unsafe_get_ad_account_for_sync/1` or move to `AdButler.Ads.Sync` sub-context
- [ ] W3: `meta/client.ex:148` — sanitize token-exchange error body before returning; extract only `code`, `type`, `error_subcode`
- [ ] W4: `ads.ex:79-290` — add `bulk_validate/2` helper that runs changeset validation, drops invalid rows with Logger.warning
- [ ] W5a: `replay_dlq_test.exs:70` — replace `Process.sleep(100)` with synchronous drain
- [ ] W5b: `plug_attack_test.exs:44` — capture original `:trusted_proxy` value before `put_env`, restore in `on_exit`
- [ ] W5c: `replay_dlq_test.exs` — add `@behaviour AdButler.AMQPBasicBehaviour` to `AMQPBasicStub`
- [ ] W6: `fetch_ad_accounts_worker.ex:19` — `Ecto.UUID.cast(id)` with `{:cancel, "invalid_meta_connection_id"}` on `:error`
- [ ] W7: Document/verify `POOL_SIZE >= 25` in `.env.example` and `fly.toml` / `Dockerfile`

---

## Skipped

None.

---

## Deferred

None.
