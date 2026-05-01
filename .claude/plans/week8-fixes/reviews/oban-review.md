# Oban Review — v0.3 + week8 fixes

⚠️ EXTRACTED FROM AGENT MESSAGE — agent could not write directly (hook-restricted).

## Summary

Three workers structurally sound. Iron Laws 2 + 4 satisfied. Prior confirmed findings (snooze semantics, unique window sizing, N+1-safe bulk fetch) not re-raised. Three new findings below.

---

## BLOCKER

**`creative_fatigue_predictor_worker.ex:455` — atom-key pattern match inside `build_evidence/1` is fragile and silently falls through post-Postgres.**

`build_factors_map/1` (line 419) stores heuristic values under `%{"values" => atom_keyed_map}` where the inner map has atom keys (e.g. `%{forecast_window_end: "...", projected_ctr_3d: 0.012, ...}`). The `build_evidence/1` pattern `%{"values" => %{forecast_window_end: end_date}}` matches correctly **in-process** (before Postgres write). Same for `render_finding_body/1` (lines 532-535).

The fragility: any future caller reconstructing `factors` from the persisted `evidence` JSONB (string keys post-Postgres) and passing back into `build_evidence/1` hits the `_` branch silently, stripping `"predicted"` and `"forecast_window_end"` from top-level evidence. Comment at line 531 acknowledges this but doesn't fix it.

**Fix:** Stringify the inner values map immediately in `build_factors_map/1`:

```elixir
defp build_factors_map(triggered) do
  Map.new(triggered, fn {kind, factors} ->
    stringified = Map.new(factors, fn {k, v} -> {to_string(k), v} end)
    {kind, %{"weight" => Map.get(@weights, kind, 0), "values" => stringified}}
  end)
end
```

Then update `build_evidence/1` and `format_predictive_clause/1` to use string keys. Delete the line-531 comment.

---

## WARNING

**`embeddings_refresh_worker.ex:179` — bare `{:ok, count} = Embeddings.bulk_upsert(rows)` raises `MatchError` if the contract widens.**

Currently `bulk_upsert/1` is `{:ok, _}`-only, but a future `{:error, _}` return (or wrapped raise) becomes an opaque crash. Replace with a `case` that handles both clauses cleanly.

```elixir
case Embeddings.bulk_upsert(rows) do
  {:ok, count} ->
    expected = length(rows)
    if count == expected do
      :ok
    else
      Logger.error("embeddings_refresh: partial upsert", kind: kind, count: expected, failure_count: expected - count)
      {:error, :partial_upsert_failure}
    end

  {:error, reason} ->
    Logger.error("embeddings_refresh: upsert failed", kind: kind, reason: reason)
    {:error, reason}
end
```

**`embeddings_refresh_worker.ex:41-43` — rate-limit snooze on "ad" silently skips "finding" for that tick.**

`with :ok <- refresh_kind("ad")` short-circuits: `{:snooze, 90}` for ads means findings never process that tick. Sustained rate-limit + max_attempts: 3 → findings could be delayed by multiple 90s snoozes within a 30-min cron window.

**Fix:** Run both kinds unconditionally, then reduce:

```elixir
def perform(_job) do
  ad_result      = refresh_kind("ad")
  finding_result = refresh_kind("finding")

  case {ad_result, finding_result} do
    {:ok, :ok}        -> :ok
    {{:snooze, s}, _} -> {:snooze, s}
    {_, {:snooze, s}} -> {:snooze, s}
    {{:error, r}, _}  -> {:error, r}
    {_, {:error, r}}  -> {:error, r}
  end
end
```

---

## SUGGESTION

**`embeddings_refresh_worker.ex:21-24` — no `timeout/1` callback.**

Two sequential `Repo.all` calls plus an embeddings API call, no timeout (`:infinity` default). A hung provider connection holds the executor indefinitely.

**Fix:** Add `@impl Oban.Worker; def timeout(_job), do: :timer.minutes(5)`.

---

## Queue Configuration & Idempotency

- Pool 53 + 12 headroom = 65. Correct.
- `fatigue_audit: 5`, `embeddings: 3`, `audit: 5` — appropriate.
- Lifeline 30 min covers predictor 10-min timeout. Pruner 7 days — fine.
- All three workers idempotent. Fatigue scores upsert on `(ad_id, computed_at)`. Findings guarded by MapSet pre-check + dedup-constraint fallback. Embeddings upsert on `(kind, ref_id)` with hash-gated change detection. FatigueNightlyRefitWorker downstream jobs deduplicated by predictor's unique window.
