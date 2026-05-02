---
title: "Test that a function's query count is invariant in N (anti-N+1 regression test)"
module: "ExUnit + :telemetry"
date: "2026-05-02"
problem_type: testing
component: ecto_test
symptoms:
  - "N+1 regression slipped past code review and was only caught by load testing"
  - "After fixing N+1, no test prevents the regression from creeping back in"
  - "Bulk function passes correctness tests but accidentally re-introduces a per-id query in a refactor"
  - "Two-run telemetry assertions flake because stale messages bleed between runs"
root_cause: "Query count is observable behaviour but not normally asserted. A function can be 'correct' in result-shape while issuing 5x or 25x the queries you intended. Without a test that asserts query count is INVARIANT in collection size, an N+1 regression is silent until production. Naive telemetry-handler tests also flake because the test process mailbox is not isolated between measurement runs."
severity: medium
tags: [ecto, testing, telemetry, n+1, performance-test, regression]
related_solutions: ["ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430"]
---

## Problem

After eliminating an N+1 (e.g. replacing 5 ads × 4 metric series queries with one bulk aggregate), you want a test that prevents the N+1 from creeping back in during a future refactor. Two failure modes to design around:

1. **Asserting `<= N` queries is too weak** — passes whether the function does 4 queries for 1 ad or 4 queries for 100 ads. The interesting property is **invariance**: query count must NOT scale with the input list size.
2. **Naive telemetry handlers flake** — `:telemetry.attach/4` with a self-mailbox-send leaks messages between measurement runs. `after 0` polling sees stale events from a prior run, perturbing the count.

## Solution

Wrap measurement in a `count_queries/1` helper that drains the mailbox before attaching, uses a unique `make_ref/0` handler ID, and detaches in `after`:

```elixir
# test/ad_butler/analytics_test.exs

test "constant-query verification — query count does NOT scale with ad_ids" do
  user = insert(:user)
  ads = for _ <- 1..5, do: insert_ad_for_user(user)
  ad_ids = Enum.map(ads, & &1.id)

  query_count = count_queries(fn -> Analytics.get_ads_delivery_summary_bulk(user, ad_ids) end)
  assert query_count <= 4,
         "expected ≤ 4 queries for a 5-ad invocation; got #{query_count}"

  # Sanity: a 1-ad invocation produces the same query count.
  one_ad_count =
    count_queries(fn -> Analytics.get_ads_delivery_summary_bulk(user, [hd(ad_ids)]) end)

  assert one_ad_count == query_count,
         "query count must be invariant in N (got #{query_count} for 5 ads, #{one_ad_count} for 1 ad)"
end

# Counts repo queries emitted while `fun` runs. Drains stale telemetry
# messages from the mailbox first so prior measurement runs cannot leak
# into this one. The handler is uniquely keyed per `make_ref/0` so
# parallel `:telemetry.attach` calls do not collide.
defp count_queries(fun) when is_function(fun, 0) do
  ref = make_ref()
  parent = self()
  handler_id = "test-bulk-query-count-#{inspect(ref)}"

  drain_query_messages()

  :telemetry.attach(
    handler_id,
    [:ad_butler, :repo, :query],
    fn _event, _measurements, _meta, _config ->
      send(parent, {:query, ref})
    end,
    nil
  )

  try do
    _ = fun.()
  after
    :telemetry.detach(handler_id)
  end

  Stream.repeatedly(fn ->
    receive do
      {:query, ^ref} -> :ok
    after
      0 -> :done
    end
  end)
  |> Enum.take_while(&(&1 == :ok))
  |> length()
end

defp drain_query_messages do
  receive do
    {:query, _} -> drain_query_messages()
  after
    0 -> :ok
  end
end
```

## Why each piece matters

- **Invariance assertion (`one_ad_count == query_count`)** — turns the test into a structural property. A future refactor that re-introduces a per-id query will fail BOTH measurements but with different counts, breaking equality.
- **`drain_query_messages/0` before each measurement** — without it, a stale `{:query, _}` from the prior run perturbs the second count and produces flaky assertions.
- **`make_ref/0`-keyed handler ID** — `:telemetry.attach` raises `:already_exists` if two parallel test cases collide on the same handler ID. `inspect(ref)` produces a unique string per call.
- **Pattern-match on `^ref`** — only count messages from THIS measurement, not any other telemetry tap that might also be feeding the mailbox.

## When to use

- Bulk read functions that aggregate over user-supplied collections (`get_X_bulk(user, ids)`).
- Any function whose contract is "constant queries regardless of input size."
- Right after eliminating an N+1, BEFORE the diff lands — burn the assertion in so a future refactor cannot silently regress.

## When NOT to use

- For a function whose query count legitimately scales with input (e.g. per-row preload cycles). For those, prefer `Repo.preload/3` correctness tests over query-count tests.
- Functions inside an `Ecto.Multi` — telemetry counts the multi-execute as a single event but the underlying queries may still be N+1; use `EXPLAIN ANALYZE` instead.

## Related

`ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430.md` covers the bulk write counterpart of this pattern (single Repo call, scoped to context boundary).
