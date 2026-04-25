# Triage: health-audit-findings-apr23

**Date:** 2026-04-23  
**Source:** health-audit-findings-review.md  
**Decision:** All findings approved for fixing.

---

## Fix Queue

### Critical

- [x] **C1** — `token_refresh_sweep_worker.ex:51` — Remove `{:error, :all_enqueues_failed}` branch; return `:ok` always; `Oban.insert_all` raises on real DB error, `succeeded == 0` is not a failure signal in steady state (on_conflict: :nothing skips not in result)

### Warnings

- [x] **W1** — `token_refresh_sweep_worker.ex:37` — Replace `length(connections) == @default_limit` check: fetch `@default_limit + 1` rows, check `length > @default_limit`, take back to limit
- [x] **W2** — `token_refresh_sweep_worker.ex:51` — Normalize MapSet key lookup: `job.args["meta_connection_id"] || job.args[:meta_connection_id]`
- [x] **W3** — `plug_attack_test.exs:87` — Flush PlugAttack ETS bucket in `setup` instead of relying on unique octet pool
- [x] **W4** — `token_refresh_sweep_worker_test.exs` — Move `Application.put_env` + `on_exit` cleanup into a named setup function so cleanup is always registered

### Suggestions — Minor fixes

- [x] **S1** — `token_refresh_sweep_worker.ex` — Log `total`, `newly_enqueued`, `skipped` at `:info` on every sweep run
- [x] **S2** — `token_refresh_sweep_worker_test.exs:19` — Fix test comment: "15 days" → "14 days" to match `@sweep_days_ahead`

### Suggestions — Documentation gaps

- [x] **S3** — `ads.ex:298` — Replace `@doc false` on `bulk_upsert_ads/2` with a real `@doc` (it is cross-context API called from MetadataPipeline)
- [x] **S4** — `application.ex` — Move `require Logger` to module top level; remove per-function `require`
- [x] **S5** — `plug_attack.ex` — Add one-line comment explaining that `nil` return means "rule did not fire" in PlugAttack
- [x] **S9** — `meta/client.ex` — Add comment on `batch_request/2` explaining why token stays in POST body (Meta Batch API does not accept Bearer)

### Suggestions — Test strengthening

- [x] **S6** — `accounts_test.exs:294` — Strengthen `stream_active_meta_connections` assertion: `assert Enum.all?(list, &(&1.status == "active"))` instead of `refute Enum.any?`
- [x] **S7** — `metadata_pipeline_test.exs:233` — Add `assert Repo.aggregate(AdButler.Ads.Ad, :count) == 0` to `list_ads :rate_limit_exceeded` test
- [x] **S8** — `auth_controller_test.exs:127` — Assert exact token value `"new_token_after_upsert"` instead of negative `!= "old_token"`

---

## Skipped

None.

## Deferred

None.
