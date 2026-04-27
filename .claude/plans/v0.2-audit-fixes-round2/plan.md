# Audit Fixes Round 2 — Review Blockers & Warnings

**Source:** `.claude/plans/v0.2-audit-fixes/reviews/audit-fixes-triage.md`
**Items:** 18 (5 blockers + 13 warnings)
**Phases:** 6

---

## Phase 1: Iron Law Fixes — Repo Boundary + Logging

### [P1-T1] Add `Ads.stream_ad_accounts_and_run/2` context function
**Agent:** [elixir]
**File:** `lib/ad_butler/ads.ex`

Add a context function mirroring `Accounts.stream_connections_and_run/2` so workers never call `Repo` directly:

```elixir
@doc "Streams active ad accounts inside a transaction; returns {:ok, fun_result} | {:error, reason}."
@spec stream_ad_accounts_and_run((Enumerable.t() -> any()), keyword()) ::
        {:ok, any()} | {:error, any()}
def stream_ad_accounts_and_run(fun, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, :timer.minutes(5))
  Repo.transaction(fn -> fun.(stream_active_ad_accounts()) end, timeout: timeout)
end
```

- [x] [P1-T1] Add `stream_ad_accounts_and_run/2` to `lib/ad_butler/ads.ex` with `@doc` and `@spec`

### [P1-T2] Refactor `InsightsSchedulerWorker` — remove `Repo`, fix O(n²), publish outside tx
**Agent:** [oban]
**Files:** `lib/ad_butler/workers/insights_scheduler_worker.ex`
**Fixes:** B1 (Repo in worker), B4 (O(n²) error accumulation), W4 (publish inside tx)

Current: worker aliases `Repo`, calls `Repo.transaction`, publishes inside the transaction.
Target: worker collects payloads via `Ads.stream_ad_accounts_and_run/1`, publishes outside.

```elixir
def perform(_job) do
  case Ads.stream_ad_accounts_and_run(fn stream ->
    stream
    |> Stream.chunk_every(200)
    |> Enum.flat_map(&Enum.map(&1, fn acct -> build_payload(acct) end))
  end) do
    {:ok, payloads} ->
      {count, errors} =
        Enum.reduce(payloads, {0, []}, fn payload, {n, errs} ->
          case publish_payload(payload) do
            :ok -> {n + 1, errs}
            {:error, r} -> {n, [{:error, r} | errs]}  # prepend, not ++
          end
        end)
      Logger.info("insights delivery scheduler complete", count: count)
      case errors do
        [] -> :ok
        [{:error, reason} | _] -> {:error, reason}
      end
    {:error, reason} -> {:error, reason}
  end
end

defp build_payload(account) do
  jitter = rem(:erlang.phash2(account.meta_id), 1800)
  Jason.encode!(%{ad_account_id: account.id, sync_type: "delivery", jitter_secs: jitter})
end

defp publish_payload(payload) do
  case publisher().publish(payload) do
    :ok -> :ok
    {:error, reason} ->
      Logger.error("insights scheduler publish failed", reason: reason)
      {:error, reason}
  end
end
```

Remove `alias AdButler.Repo`. Keep `alias AdButler.Ads`.

- [x] [P1-T2] Refactor `InsightsSchedulerWorker`: use `Ads.stream_ad_accounts_and_run/1`, remove `Repo`, fix O(n²), publish outside tx

### [P1-T3] Fix Logger string interpolation in `auth_controller.ex`
**Agent:** [elixir]
**File:** `lib/ad_butler_web/controllers/auth_controller.ex:50`
**Fix:** B2

Change:
```elixir
Logger.warning("OAuth error from provider (truncated): #{safe_description}")
```
To:
```elixir
Logger.warning("oauth_provider_error", description: safe_description)
```

Add `:description` to the Logger metadata list in `config/config.exs` if not already present.

- [x] [P1-T3] Fix `Logger.warning` string interpolation in `auth_controller.ex:50`; add `:description` to Logger metadata in `config.exs`

---

## Phase 2: Pipeline Resilience + Analytics SQL Safety

### [P2-T1] Fix bare match in `insights_pipeline.ex`
**Agent:** [elixir]
**File:** `lib/ad_butler/sync/insights_pipeline.ex:118`
**Fix:** B3

Change:
```elixir
{:ok, count} = Ads.bulk_upsert_insights(normalised)
```
To:
```elixir
case Ads.bulk_upsert_insights(normalised) do
  {:ok, count} ->
    Logger.info("insights upserted", ...)
    :ok
  {:error, reason} ->
    Logger.error("insights upsert failed", ...)
    {:error, reason}
end
```

Move the `Logger.info("insights upserted", ...)` lines (currently below the bare match at line 120-125) inside the `{:ok, count}` clause.

- [x] [P2-T1] Wrap `Ads.bulk_upsert_insights` in `case` inside `fetch_and_upsert/4`; return `{:error, reason}` on failure

### [P2-T2] Fix SQL safety in `analytics.ex`
**Agent:** [elixir]
**File:** `lib/ad_butler/analytics.ex:33-44, 87`
**Fix:** B5, W7

Two changes:
1. In `create_future_partitions/0`: apply `safe_identifier!(pname)` before interpolating into `CREATE TABLE`. The date values from `Date.to_iso8601/1` are always `YYYY-MM-DD` (safe), but add an inline comment confirming this.
2. In `do_refresh/1`: apply `safe_identifier!(view_name)` before interpolating into `REFRESH MATERIALIZED VIEW CONCURRENTLY`.

```elixir
defp do_refresh(view_name) do
  safe_name = safe_identifier!(view_name)
  {duration_us, _} = :timer.tc(fn ->
    Repo.query!("REFRESH MATERIALIZED VIEW CONCURRENTLY #{safe_name}")
  end)
  ...
end
```

```elixir
# in create_future_partitions/0:
safe_pname = safe_identifier!(pname)
# ws and we come from Date arithmetic — Date.to_iso8601 always returns YYYY-MM-DD
Repo.query!("""
CREATE TABLE IF NOT EXISTS "#{safe_pname}"
PARTITION OF insights_daily
FOR VALUES FROM ('#{Date.to_iso8601(ws)}') TO ('#{Date.to_iso8601(we)}')
""")
```

- [x] [P2-T2] Apply `safe_identifier!` to `pname` in `create_future_partitions/0` and to `view_name` in `do_refresh/1`

---

## Phase 3: Worker & Context Cleanup

### [P3-T1] Switch `InsightsConversionWorker` to streaming path
**Agent:** [oban]
**File:** `lib/ad_butler/workers/insights_conversion_worker.ex`
**Fix:** W3

Current uses `Ads.list_ad_accounts_internal()` (loads all into memory). Change to use `Ads.stream_ad_accounts_and_run/1` (same pattern as the refactored scheduler worker), with publishing outside the transaction.

```elixir
def perform(_job) do
  case Ads.stream_ad_accounts_and_run(fn stream ->
    Enum.map(stream, fn account ->
      jitter = rem(:erlang.phash2(account.meta_id), 1800)
      Jason.encode!(%{ad_account_id: account.id, sync_type: "conversions", jitter_secs: jitter})
    end)
  end) do
    {:ok, payloads} ->
      results = Enum.map(payloads, &publisher().publish/1)
      Logger.info("insights conversion scheduler complete", count: length(payloads))
      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> :ok
        {:error, reason} -> {:error, reason}
      end
    {:error, reason} -> {:error, reason}
  end
end
```

- [x] [P3-T1] Refactor `InsightsConversionWorker` to use `Ads.stream_ad_accounts_and_run/1`, publish outside tx

### [P3-T2] Fix O(n²) in `meta/client.ex`
**Agent:** [elixir]
**File:** `lib/ad_butler/meta/client.ex:229,232`
**Fix:** W5

Change `acc ++ data` to prepend + final reverse:
```elixir
# recursive call: accumulate with prepend
fetch_all_pages(method, next_url, headers, [], ad_account_id, [data | acc])

# base case: reverse accumulated list and flatten
{:ok, acc |> Enum.reverse() |> List.flatten()}
```

Note: since `acc` stores sublists and `data` is a list, use `[data | acc]` and `List.flatten(Enum.reverse(acc))`.

- [x] [P3-T2] Fix `acc ++ data` O(n²) in `meta/client.ex:229,232` to prepend + reverse

### [P3-T3] Add `unsafe_` prefix to unscoped insight query functions
**Agent:** [elixir]
**File:** `lib/ad_butler/ads.ex:591-640`
**Fix:** W8

Rename `get_7d_insights/1` → `unsafe_get_7d_insights/1` and `get_30d_baseline/1` → `unsafe_get_30d_baseline/1`. Add `@doc` note that caller must verify `ad_id` ownership before calling. Update callers (check `lib/ad_butler_web/`, `lib/ad_butler/sync/`) to use the new names.

- [x] [P3-T3] Rename insight query functions to `unsafe_*`; update callers; add ownership doc note

### [P3-T4] Add all-zeros Cloak key check for prod
**Agent:** [elixir]
**File:** `config/runtime.exs:35-39`
**Fix:** W9

After the existing 32-byte size check, add:
```elixir
if cloak_key == <<0::256>> do
  raise "CLOAK_KEY must not be the all-zeros placeholder in prod"
end
```

- [x] [P3-T4] Add `<<0::256>>` check for `CLOAK_KEY` in `:prod` block of `runtime.exs`

### [P3-T5] Call `meta_client()` once per batch in `insights_pipeline.ex`
**Agent:** [elixir]
**File:** `lib/ad_butler/sync/insights_pipeline.ex:88`
**Fix:** W10

`meta_client()` is called inside `sync_insights_message/3`, which is called per-message. Move the `client = meta_client()` call to the top of `handle_batch/4` and thread it through `process_batch_group/3` and `sync_insights_message/3`.

- [x] [P3-T5] Hoist `meta_client()` call to `handle_batch/4`; thread `client` through `process_batch_group/3` and `sync_insights_message/3`

---

## Phase 4: Code Quality

### [P4-T1] Fix `@spec` for `bulk_upsert_insights`
**Agent:** [elixir]
**File:** `lib/ad_butler/ads.ex:556`
**Fix:** W1

```elixir
@spec bulk_upsert_insights([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
```

- [x] [P4-T1] Fix `@spec bulk_upsert_insights` to include `| {:error, term()}`

### [P4-T2] Remove redundant `import Ecto.Query` inside function bodies
**Agent:** [elixir]
**File:** `lib/ad_butler/ads.ex:593,620`
**Fix:** W2

Delete the `import Ecto.Query` line from inside `unsafe_get_7d_insights/1` and `unsafe_get_30d_baseline/1` (after P3-T3 rename). The module-level import at line 9 already covers these.

- [x] [P4-T2] Remove redundant `import Ecto.Query` from inside both insight query function bodies

### [P4-T3] Fix migration `down` to drop initial partitions
**Agent:** [elixir]
**File:** `priv/repo/migrations/20260426100002_create_insights_initial_partitions.exs`
**Fix:** W6

The `down/0` only drops the PL/pgSQL function, not the 4 partitions it created. Add explicit `DROP TABLE IF EXISTS` calls:

```elixir
def down do
  execute "DROP TABLE IF EXISTS insights_daily_#{current_week_name()}"
  # ... for all 4 week offsets (0, 7, 14, 21 days)
  execute "DROP FUNCTION IF EXISTS create_insights_partition(DATE)"
end
```

Since partition names depend on the date at migration time (not deterministic at rollback time), use the same PL/pgSQL approach: create a `drop_insights_partition` helper or use a loop via `pg_inherits` to drop all child tables of `insights_daily` that exist at rollback time.

Simplest approach:
```elixir
def down do
  execute """
  DO $$
  DECLARE r RECORD;
  BEGIN
    FOR r IN SELECT child.relname FROM pg_inherits
             JOIN pg_class child ON child.oid = pg_inherits.inhrelid
             JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
             WHERE parent.relname = 'insights_daily'
    LOOP
      EXECUTE 'DROP TABLE IF EXISTS ' || quote_ident(r.relname);
    END LOOP;
  END $$;
  """
  execute "DROP FUNCTION IF EXISTS create_insights_partition(DATE)"
end
```

- [x] [P4-T3] Fix migration `down` to drop all `insights_daily` child partitions before dropping the function

---

## Phase 5: Tests

### [P5-T1] Tenant isolation tests for insight query functions
**Agent:** [testing]
**File:** `test/ad_butler/ads/ads_insights_test.exs`
**Fix:** W11

Add two-user cross-tenant tests for `unsafe_get_7d_insights/1` and `unsafe_get_30d_baseline/1`. These query materialized views by `ad_id` directly. Since these are views over `insights_daily` (which is scoped by `ad_id` FK → `ads` → `ad_accounts` → `meta_connections` → `users`), the test should:
1. Insert an insight row for `user_a`'s ad
2. Assert that querying with `user_b`'s ad_id returns `{:ok, nil}`
3. Assert that querying with `user_a`'s ad_id returns the row

Note: these views are `WITH NO DATA` in test — use raw `insert_all` into `ad_insights_7d` / `ad_insights_30d` via `execute` in test setup, or tag with `:skip` and add a comment explaining the view constraint. If views can't be populated in test, document the limitation with a `@tag :requires_populated_views` and skip in CI.

- [x] [P5-T1] Add (or tag+skip) tenant isolation tests for `unsafe_get_7d_insights/1` and `unsafe_get_30d_baseline/1`

### [P5-T2] Missing tests in `InsightsConversionWorkerTest`
**Agent:** [testing]
**File:** `test/ad_butler/workers/insights_conversion_worker_test.exs`
**Fix:** W12

Add:
1. `"inactive ad accounts are excluded"` — insert an ad account with `status: :inactive`; assert it is not included in published payloads (use configurable publisher to capture calls)
2. `"returns {:error, reason} when publish fails"` — configure publisher to return `{:error, :down}`; assert `perform/1` returns `{:error, _}`

- [x] [P5-T2] Add inactive-account exclusion test and publish-failure test to `InsightsConversionWorkerTest`

### [P5-T3] Fix ISO week year boundary issue in partition test
**Agent:** [testing]
**File:** `test/ad_butler/workers/partition_manager_worker_test.exs:22-38`
**Fix:** W13

`create_old_partition/0` uses `old_date.year` but `:calendar.iso_week_number/1` returns `{iso_year, week}` where `iso_year` can differ from `old_date.year` near year boundaries (Dec 29-31).

Fix: use the `iso_year` from `:calendar.iso_week_number/1` to build the partition name, matching what `Analytics.partition_name/1` actually does:

```elixir
defp create_old_partition do
  old_date = Date.add(Date.utc_today(), -400)
  {iso_year, iso_week} = :calendar.iso_week_number({old_date.year, old_date.month, old_date.day})
  pname = "insights_daily_#{iso_year}_W#{String.pad_leading(Integer.to_string(iso_week), 2, "0")}"
  ...
end
```

- [x] [P5-T3] Fix `create_old_partition/0` to derive partition name from `iso_year` (from `:calendar.iso_week_number/1`), not `old_date.year`

---

## Phase 6: Verification

- [x] [P6-T1] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix compile --warnings-as-errors` — must be clean
- [x] [P6-T2] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix format --check-formatted` — must be clean
- [x] [P6-T3] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix credo --strict` — must be 0 issues
- [x] [P6-T4] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix test` — must be 0 failures
