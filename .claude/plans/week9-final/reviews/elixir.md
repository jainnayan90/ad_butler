# Code Review: W9 Final Triage Fixes (elixir-reviewer, post-fix pass)

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim. See scratchpad 2026-05-02 entry.

**Status**: ⚠️ Changes Requested | **Issues**: 2 WARNINGs, 2 SUGGESTIONs, 1 NIT

---

## WARNING 1 — `analytics.ex:365` — Bare pattern match on `Ecto.UUID.load/1`

```elixir
{:ok, uuid} = Ecto.UUID.load(bin)   # raises MatchError if :error
```

`Ecto.UUID.load/1` returns `{:ok, uuid} | :error`. This runs inside `Map.new/2` in `build_bulk_delivery_summary/2` — one malformed 16-byte binary from the DB crashes the entire bulk call with an uncaught `MatchError`, failing the whole chat turn. Replace with a `case` expression.

---

## WARNING 2 — `ads.ex:171-173` — `rescue Ecto.Query.CastError` in `filter_owned_ad_ids/2` is too broad

The `rescue` wraps `Repo.all/1`. Any `DBConnection.ConnectionError` or `Postgrex.Error` is silently swallowed and returns `[]`, making `get_ads_delivery_summary_bulk/3` silently appear to find no owned ads without logging. Since `ad_ids` are internal UUIDs (fetched via `Ads.fetch_ad/2` upstream), the `CastError` path is dead code anyway — remove the rescue and pre-filter with `Ecto.UUID.dump/1` like `build_bulk_delivery_summary/2` already does.

---

## SUGGESTION 3 — `server.ex:320-333` — `normalise_params/1` drops valid params when one unknown key triggers the rescue

If the LLM emits `%{"ad_ids" => [...], "unknown_key" => "x"}`, the entire `Map.new/2` rescues on `"unknown_key"`, and then `"ad_ids"` is also silently dropped (only pre-existing atom keys survive). Jido sees empty params and returns a confusing schema-validation error. Fix: iterate key-by-key using an `Enum.reduce`, rescuing `ArgumentError` per-key so only the unknown key is dropped.

---

## SUGGESTION 4 — `compare_creatives.ex:79` — `Map.get/2` on `AdHealthScore` struct is non-idiomatic

`health_metric(score, key)` calls `Map.get(score, key)` where `score :: AdHealthScore.t()`. Use two explicit function heads (`health_metric(%AdHealthScore{fatigue_score: v}, :fatigue_score)` etc.) for compile-time safety and to prevent silently returning `nil` if an incorrect field atom is ever passed.

---

## NIT 5 — `analytics.ex:305-313` — Redundant `case owned` after existing empty-list head clause

The `def …([], _opts), do: %{}` head clause already short-circuits empty input. The post-filter `case owned do [] -> %{}` is still semantically needed (filter may yield empty even with non-empty input), but an `if owned == []` reads more directly than a `case` with a single non-empty clause.
