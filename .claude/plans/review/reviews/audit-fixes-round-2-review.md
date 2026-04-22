# Review: Audit Fixes Round 2 — 2026-04-22
**Verdict: PASS WITH WARNINGS**
**Issues**: 0 blockers, 5 warnings, 3 suggestions

Agents: elixir-reviewer, security-analyzer, testing-reviewer, oban-specialist.
mix test: 132 tests, 0 failures ✅

---

## Prior Round-2 Findings — ALL RESOLVED

| ID | Finding | Status |
|----|---------|--------|
| MF-1 | nil ad_set_id crash in bulk ad insert | ✅ Orphan guard added |
| MF-2 | Oban.insert_all return discarded | ✅ Handled (is_list guard) |
| MF-3 | bulk_upsert_ads/2 zero tests | ✅ 2 tests added |
| MF-4 | Pipeline never exercises ads code path | ✅ 2 pipeline ads tests added |
| W1 | bulk_upsert_ads result silently discarded | ✅ upserted_count logged |
| W2 | get_ad_account_for_sync public unscoped | ✅ Renamed unsafe_ |
| W3 | Token-exchange error leaks body to logs | ✅ Sanitized to {code,type,subcode} |
| W4 | bulk_upsert_* skips changeset validation | ✅ bulk_validate/2 added |
| W5 | Process.sleep, hardcoded env, missing @behaviour | ✅ All three fixed |
| W6 | FetchAdAccountsWorker no UUID cast | ✅ Ecto.UUID.cast/1 added |
| W7 | Pool size vs sync queue undocumented | ✅ Comment + .env.example |

---

## Warnings

### W1 — Dead `{:error, reason}` arm in SyncAllConnectionsWorker — Dialyzer will flag
`lib/ad_butler/workers/sync_all_connections_worker.ex:22-25`

`Oban.insert_all/1` in Oban 2.21.1 always returns a list — never `{:error, reason}`. On DB failure it **raises** rather than returning an error tuple. The `{:error, reason}` arm is unreachable dead code; Dialyzer will flag this as `pattern_match`. Real insert failures surface as uncaught raises (Oban catches them and marks job retryable — correct behavior, just not via this path).

```elixir
# Fix — remove dead arm
Oban.insert_all(jobs)
:ok
```

### W2 — AMQPBasicBehaviour ack/nack specs too narrow — Dialyzer `invalid_contract`
`lib/ad_butler/amqp_basic_behaviour.ex:15-17`

`AMQP.Basic.ack/2` and `nack/3` return `:ok | {:error, term()}`. The `@callback` specs declare only `:ok`. Any real AMQP implementation will fail Dialyzer's contract check.

```elixir
@callback ack(channel :: term(), delivery_tag :: term()) :: :ok | {:error, term()}
@callback nack(channel :: term(), delivery_tag :: term(), opts :: keyword()) :: :ok | {:error, term()}
```

### W3 — `exchange_code/1` non-map body produces silent all-nil safe struct
`lib/ad_butler/meta/client.ex:148-155`

The `{:ok, %{body: body}}` catch-all fires on any non-200 response. If Req returns an undecoded binary body (unexpected content-type, network error), `get_in(binary, ["error", "code"])` returns `nil` — no crash, but `{:token_exchange_failed, %{code: nil, type: nil, subcode: nil}}` is indistinguishable from a genuine Meta error with no error envelope. Operators lose diagnostic context.

```elixir
{:ok, %{body: body}} when is_map(body) ->
  safe = %{code: get_in(body, ["error", "code"]), ...}
  {:error, {:token_exchange_failed, safe}}

{:ok, %{status: status}} ->
  {:error, {:token_exchange_failed, %{code: nil, type: nil, subcode: nil, status: status}}}
```

### W4 — Missing test for `{:cancel, "invalid_meta_connection_id"}` path
`lib/ad_butler/workers/fetch_ad_accounts_worker.ex:22`

The UUID cast (`Ecto.UUID.cast/1`) was the whole point of the W6 fix, but there is no test exercising the `:error` branch. A non-UUID job arg currently burns all 5 retries before discarding — the cancel path is the fix for that, but it's untested.

```elixir
test "cancels job when meta_connection_id is not a valid UUID" do
  assert {:cancel, "invalid_meta_connection_id"} =
           perform_job(FetchAdAccountsWorker, %{"meta_connection_id" => "not-a-uuid"})
end
```

### W5 — `inspect(reason)` drifts from `ErrorHelpers.safe_reason/1` pattern at 3 sites
`lib/ad_butler/workers/fetch_ad_accounts_worker.ex:76,91`; `lib/ad_butler/sync/metadata_pipeline.ex:101`

`token_refresh_worker.ex` already uses `AdButler.ErrorHelpers.safe_reason/1`. These three sites use `inspect(reason)`. While W3 sanitized the specific token-exchange error shape, other error shapes from `Meta.Client.handle_error/1` (e.g. `{:bad_request, msg}` where `msg` is Meta's error.message string) may echo user identifiers to logs. Consistency with the existing helper also future-proofs against new error shapes.

---

## Suggestions

### S1 — Orphan-drop test assertion too coarse (count only, not which ad)
`test/ad_butler/sync/metadata_pipeline_test.exs:170`

`assert Repo.aggregate(Ad, :count) == 1` verifies count but not which ad was kept. If implementation accidentally persists the orphan and drops the good ad, the count still equals 1. Add:

```elixir
[ad] = Repo.all(AdButler.Ads.Ad)
assert ad.meta_id == "ad_good"
```

### S2 — `plug_attack_test.exs` on_exit restores `nil` instead of deleting env
`test/ad_butler_web/plugs/plug_attack_test.exs:44`

`config.exs` sets `trusted_proxy: false` but `test.exs` doesn't override it, so `Application.get_env` returns `nil` at test startup. `on_exit` restores `nil` via `put_env`, leaving the key set to `nil` instead of being absent. Functionally equivalent for `== :fly` checks, but semantically wrong:

```elixir
on_exit(fn ->
  case original do
    nil -> Application.delete_env(:ad_butler, :trusted_proxy)
    val -> Application.put_env(:ad_butler, :trusted_proxy, val)
  end
end)
```

### S3 — `bulk_validate/2` passes raw attrs to `insert_all`, not changeset.changes
`lib/ad_butler/ads.ex:308-324`

Validates with `changeset.valid?` but returns the *original* attrs map. `Repo.insert_all` does not run type casts — if a future `build_*_attrs` adds a field not in the schema, Postgrex raises. Consider `Map.take(attrs, schema_mod.__schema__(:fields))` on valid entries to prune unknown keys defensively.

---

## Noise Filtered Out

- Atom keys in `perform_job` test calls — functional, Oban.Testing converts them to string keys.
- Snooze incrementing attempts — pre-existing concern, not introduced by this diff.
- `bulk_validate` double-validates ad_set campaign_id — defence-in-depth, not a bug.
