# Scratchpad: Audit Fixes Round 2

## Key Decisions

- P2-T2 `bulk_validate/2`: use `struct(schema_mod)` + `changeset/2` — all schemas have zero-arg structs, safe.
- P2-T3: Extract `FetchAdAccountsWorker` body into `run_sync/1` to keep UUID-cast in `perform/1` clean.
- P3-T2: Assert bulk_upsert_ads by DB state (not Mox) — it's a context function, not a behaviour.
- P1-T1 orphan guard mirrors existing `upsert_ad_sets` pattern exactly — consistent approach.

## Dead Ends to Avoid

- Do NOT use `Mox.expect` on `Ads.bulk_upsert_ads/2` directly — it's not a mocked behaviour.
- Do NOT add `bulk_validate` to the public API — keep it private to avoid callers bypassing bulk path.
