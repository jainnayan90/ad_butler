# Audit Fixes Round 3 — Worker, Pipeline & Analytics Polish

**Source:** `.claude/plans/v0.2-audit-fixes-round2/reviews/audit-fixes-round2-triage.md`
**Items:** 12 (8 warnings + 4 suggestions)
**Phases:** 5

---

## Phase 1: Worker Fixes

### [P1-T1] Remove `Stream.chunk_every` from `InsightsSchedulerWorker.collect_payloads/1`
**Agent:** [oban]
**File:** `lib/ad_butler/workers/insights_scheduler_worker.ex:42-44`
**Fix:** W2

Replace:
```elixir
defp collect_payloads(stream) do
  stream
  |> Stream.chunk_every(200)
  |> Enum.flat_map(&Enum.map(&1, fn acct -> build_payload(acct) end))
end
```
With:
```elixir
defp collect_payloads(stream) do
  Enum.map(stream, &build_payload/1)
end
```

- [x] [P1-T1] Simplify `collect_payloads/1` to `Enum.map(stream, &build_payload/1)` — remove no-op `Stream.chunk_every`

---

### [P1-T2] Fix `Jason.encode!` → safe `Jason.encode/1` in both workers
**Agent:** [oban]
**Files:** `lib/ad_butler/workers/insights_scheduler_worker.ex`, `lib/ad_butler/workers/insights_conversion_worker.ex`
**Fix:** W3

In `InsightsSchedulerWorker.build_payload/1`:
```elixir
defp build_payload(account) do
  jitter = rem(:erlang.phash2(account.meta_id), 1800)
  case Jason.encode(%{ad_account_id: account.id, sync_type: "delivery", jitter_secs: jitter}) do
    {:ok, payload} -> {:ok, payload}
    {:error, reason} ->
      Logger.error("insights scheduler encode failed", ad_account_id: account.id, reason: reason)
      {:error, reason}
  end
end
```

Then `collect_payloads/1` must filter out errors:
```elixir
defp collect_payloads(stream) do
  stream
  |> Enum.map(&build_payload/1)
  |> Enum.filter(&match?({:ok, _}, &1))
  |> Enum.map(fn {:ok, payload} -> payload end)
end
```

Apply the same pattern to `InsightsConversionWorker.collect_payloads/1`.

- [x] [P1-T2] Replace `Jason.encode!` with `Jason.encode/1` + error logging in both workers; filter encode errors before publishing

---

### [P1-T3] Add publish error logging to `InsightsConversionWorker`
**Agent:** [oban]
**File:** `lib/ad_butler/workers/insights_conversion_worker.ex`
**Fix:** W1

Switch from `Enum.map` + `Enum.find` to the same `Enum.reduce` + `Logger.error` pattern used in `InsightsSchedulerWorker`:

```elixir
{count, errors} = Enum.reduce(payloads, {0, []}, &publish_and_accumulate/2)
Logger.info("insights conversion scheduler complete", count: count)

case errors do
  [] -> :ok
  [{:error, reason} | _] -> {:error, reason}
end

defp publish_and_accumulate(payload, {n, errs}) do
  case publisher().publish(payload) do
    :ok -> {n + 1, errs}
    {:error, r} ->
      Logger.error("insights conversion publish failed", reason: r)
      {n, [{:error, r} | errs]}
  end
end
```

- [x] [P1-T3] Add `Logger.error` on publish failure and `publish_and_accumulate/2` helper to `InsightsConversionWorker`; mirror scheduler pattern

---

### [P1-T4] Align `publisher()` default modules in both workers
**Agent:** [oban]
**Files:** `lib/ad_butler/workers/insights_conversion_worker.ex:46`, `lib/ad_butler/workers/insights_scheduler_worker.ex:63`
**Fix:** W5

Both workers use the `:insights_publisher` config key. Align defaults to `AdButler.Messaging.PublisherPool` (the pool is correct for production fan-out). `InsightsConversionWorker` currently defaults to `AdButler.Messaging.Publisher` (non-pooled).

- [x] [P1-T4] Change `InsightsConversionWorker.publisher/0` default to `AdButler.Messaging.PublisherPool`

---

### [P1-T5] Add `timeout/1` Oban callback to both workers
**Agent:** [oban]
**Files:** `lib/ad_butler/workers/insights_scheduler_worker.ex`, `lib/ad_butler/workers/insights_conversion_worker.ex`
**Fix:** W8

After `@impl Oban.Worker` block, add:
```elixir
@impl Oban.Worker
def timeout(_job), do: :timer.minutes(6)
```
This is 1 minute above the 5-minute `stream_ad_accounts_and_run` DB transaction timeout, ensuring the DB call fails cleanly before Oban kills the job.

- [x] [P1-T5] Add `timeout/1` callback (6 minutes) to both scheduler workers

---

### [P1-T6] Document partial-publish idempotency assumption in both workers
**Agent:** [oban]
**Files:** `lib/ad_butler/workers/insights_scheduler_worker.ex`, `lib/ad_butler/workers/insights_conversion_worker.ex`
**Fix:** W7

Add to `@moduledoc` of both workers:
> **Retry behaviour:** This worker is not fully idempotent — a retry after partial failure republishes messages to accounts that already received one. Downstream consumers of `ad_butler.insights.*` queues must be idempotent (safe to process duplicate messages).

- [x] [P1-T6] Add idempotency warning to `@moduledoc` of both scheduler workers

---

## Phase 2: Context & Pipeline Fixes

### [P2-T1] Fix `bulk_upsert_insights/1` rescue — return atom, log at boundary
**Agent:** [elixir]
**File:** `lib/ad_butler/ads.ex:597-599`
**Fix:** W6

Replace:
```elixir
rescue
  e -> {:error, e}
```
With:
```elixir
rescue
  e ->
    Logger.error("bulk_upsert_insights failed", reason: Exception.message(e))
    {:error, :upsert_failed}
```

- [x] [P2-T1] Replace raw exception rescue with logged atom reason in `bulk_upsert_insights/1`

---

### [P2-T2] Add `:updated_at` to `bulk_upsert_insights/1` on_conflict replace list
**Agent:** [elixir]
**File:** `lib/ad_butler/ads.ex:577-593`
**Fix:** S1

Add `:updated_at` to the conflict replace list so upserted rows reflect the most recent sync time. Also ensure each entry map includes `Map.put(:updated_at, now)` alongside `:inserted_at`:

```elixir
entries =
  Enum.map(rows, fn row ->
    row
    |> Map.put_new(:inserted_at, now)
    |> Map.put(:updated_at, now)
  end)
```

And in the `on_conflict` replace list add: `:updated_at`

Also added `updated_at` column to `insights_daily` migration and `Insight` schema (column was missing).

- [x] [P2-T2] Add `:updated_at` to `bulk_upsert_insights` on_conflict replace list and set it on each entry

---

### [P2-T3] Replace `Date.from_iso8601!` with safe variant in `normalise_row/2`
**Agent:** [elixir]
**File:** `lib/ad_butler/sync/insights_pipeline.ex:151`
**Fix:** S2

```elixir
defp normalise_row(row, meta_id_map) do
  date =
    case row.date_start do
      s when is_binary(s) ->
        case Date.from_iso8601(s) do
          {:ok, d} -> d
          {:error, _} ->
            Logger.warning("insights: invalid date_start, skipping", date_start: s)
            nil
        end
      d ->
        d
    end

  row
  |> Map.put(:ad_id, meta_id_map[row.ad_id])
  |> Map.put(:date_start, date)
end
```

Also filter nil `date_start` before calling `bulk_upsert_insights` (it's a required field) in `fetch_and_upsert/4`.

- [x] [P2-T3] Replace `Date.from_iso8601!` with safe `Date.from_iso8601/1` + warning log in `normalise_row/2`; filter nil dates before upsert

---

## Phase 3: Analytics Fixes

### [P3-T1] Fix `@spec refresh_view/1` — spec doesn't match implementation
**Agent:** [elixir]
**File:** `lib/ad_butler/analytics.ex:14-16`
**Fix:** W4

`do_refresh/1` calls `Repo.query!` which raises on DB failure. The spec claiming `{:error, String.t()}` is misleading — callers matching on `{:error, _}` will never catch DB errors.

Change spec to:
```elixir
@doc "Refreshes the materialized view for the given period. Raises on DB error."
@spec refresh_view(String.t()) :: :ok | {:error, String.t()}
```

The `{:error, String.t()}` path is only reachable via the `"unknown view"` clause — the spec is actually correct for that. The misleading part is that callers assume it covers DB errors. Add a `@doc` note:

```elixir
@doc ~S[Refreshes the materialized view for the given period (`"7d"` or `"30d"`).
Returns `{:error, "unknown view: ..."}` for unknown period strings.
Raises `Postgrex.Error` or `DBConnection.ConnectionError` on database failure.]
```

- [x] [P3-T1] Add `@doc` note to `refresh_view/1` clarifying DB failures raise; do NOT change spec (it's correct for the unknown-view path)

---

### [P3-T2] Double-quote view name in `do_refresh/1`
**Agent:** [elixir]
**File:** `lib/ad_butler/analytics.ex:91`
**Fix:** S3

Change:
```elixir
Repo.query!("REFRESH MATERIALIZED VIEW CONCURRENTLY #{safe_name}")
```
To:
```elixir
Repo.query!(~s[REFRESH MATERIALIZED VIEW CONCURRENTLY "#{safe_name}"])
```

Consistent with how partition names are quoted in `create_future_partitions/0` and `maybe_detach_partition/2`.

- [x] [P3-T2] Wrap `safe_name` in double-quotes in `do_refresh/1` for DDL consistency

---

## Phase 4: CI Guardrails

### [P4-T1] Add mix alias grep gate for `Ads.unsafe_` in web/LiveView files
**Agent:** [elixir]
**File:** `mix.exs`
**Fix:** S4

Add a mix alias that fails if any web or LiveView file references `Ads.unsafe_`:

```elixir
"check.unsafe_callers": [
  "cmd grep -rn 'Ads\\.unsafe_' lib/ad_butler_web lib/ad_butler/sync lib/ad_butler/workers && echo 'ERROR: Ads.unsafe_ called from non-context code' && exit 1 || exit 0"
]
```

Then add `"check.unsafe_callers"` to the `precommit` alias.

> **Note:** The grep should NOT fail if `ads.ex` itself is matched — only web/LiveView/sync/worker files. The `lib/ad_butler/ads.ex` definitions are expected. Scope the grep to exclude `lib/ad_butler/ads.ex`.

- [x] [P4-T1] Add `check.unsafe_callers` mix alias and include in `precommit`; grep excludes `lib/ad_butler/ads.ex` itself

---

## Phase 5: Verification

- [x] [P5-T1] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix compile --warnings-as-errors`
- [x] [P5-T2] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix format --check-formatted`
- [x] [P5-T3] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix credo --strict`
- [x] [P5-T4] Run `CLOAK_KEY_DEV=$(openssl rand -base64 32) mix test`
