---
title: "Bulk-aggregate across contexts without crossing schema boundaries (filter_owned_X_ids helper)"
module: "Phoenix Context"
date: "2026-05-02"
problem_type: architecture
component: phoenix_context
symptoms:
  - "Bulk read function in Context A needs to scope by user-owned entities owned by Context B"
  - "Tempting to alias B's schemas (Ad, AdAccount) into A — violates context boundary Iron Law"
  - "Naive fix: pre-filter with N calls to B.fetch_X(user, id) — re-introduces an N+1 at the ownership step"
  - "End state has correct tenant scope but query count scales linearly with input list (5 ads → 10+ queries before the bulk)"
root_cause: "Cross-context bulk aggregation has two competing constraints: (1) tenant-scope each input id (lives in Context B's domain) and (2) issue ONE query for the aggregate (lives in Context A). If Context A reaches into B's schemas to do its own scoped query, the boundary breaks. If Context A calls B.fetch_X per id, scoping is correct but you N+1 the ownership step."
severity: medium
tags: [phoenix, context, bulk, n+1, tenant-scope, architecture, iron-law]
related_solutions: ["ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430"]
---

## Problem

`AdButler.Chat.Tools.CompareCreatives` needed a 7-day delivery summary across up to 5 user-supplied ad ids — spend, impressions, avg ctr, avg cpm, plus latest health score per ad. The original code was:

```elixir
# 5 ads × (1 fetch_ad scope query + 4 metric series queries + 1 health query) = ~30 queries
ads
|> Enum.map(&Ads.fetch_ad(user, &1))
|> Enum.map(fn ad ->
  spend = sum_points(Analytics.get_insights_series(ad.id, :spend, :last_7d))
  # ...3 more series calls...
  health = Analytics.unsafe_get_latest_health_score(ad.id)
  # ...
end)
```

Goal: collapse to a constant-query envelope. Two boundary problems:

1. The bulk aggregate query lives in `Analytics`. But `Ad` and `AdAccount` schemas live in `Ads`. CLAUDE.md forbids `Analytics` from aliasing `Ads.Ad` directly (Iron Law: schemas live in their owning context).
2. Tenant scope (`MetaConnection.id` chain) is `Ads`'s responsibility — `Analytics` has no business duplicating that join.

## Solution

Add a public helper to Context B (`Ads`) that filters a user-supplied id list to user-owned ids. Context A (`Analytics`) calls it ONCE up-front, then runs its bulk queries on the filtered list — no per-id scope query, no schema reach-across.

```elixir
# lib/ad_butler/ads.ex
@doc """
Returns the subset of `ad_ids` owned by `user`. Cross-tenant or unknown
ids are silently dropped. Used by chat tools / analytics that operate on
a user-supplied list; the returned list preserves no order guarantee.

Empty input or all-foreign returns `[]`. Invalid (non-UUID) strings are
pre-filtered via `Ecto.UUID.cast/1` so the underlying scoped query never
sees a malformed id.
"""
@spec filter_owned_ad_ids(User.t(), [binary()]) :: [binary()]
def filter_owned_ad_ids(%User{} = _user, []), do: []

def filter_owned_ad_ids(%User{} = user, ad_ids) when is_list(ad_ids) do
  valid =
    Enum.flat_map(ad_ids, fn id ->
      case Ecto.UUID.cast(id) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)

  case valid do
    [] -> []
    ids ->
      mc_ids = Accounts.list_meta_connection_ids_for_user(user)

      Ad
      |> scope(mc_ids)
      |> where([a], a.id in ^ids)
      |> select([a], a.id)
      |> Repo.all()
  end
end
```

Then Context A funnels every caller-supplied list through it:

```elixir
# lib/ad_butler/analytics.ex
def get_ads_delivery_summary_bulk(%User{} = user, ad_ids, opts \\ []) when is_list(ad_ids) do
  window_days = Keyword.get(opts, :window_days, 7)
  owned = Ads.filter_owned_ad_ids(user, ad_ids)

  if owned == [] do
    %{}
  else
    build_bulk_delivery_summary(owned, window_days)
  end
end

defp build_bulk_delivery_summary(ad_ids, window_days) do
  bins = dump_uuids(ad_ids)
  cutoff = Date.add(Date.utc_today(), -(window_days - 1))

  delivery_rows =
    Repo.all(
      from i in "insights_daily",
        where: i.ad_id in ^bins and i.date_start >= ^cutoff,
        group_by: i.ad_id,
        select: %{...aggregates...}
    )

  health_rows =
    Repo.all(
      from s in AdHealthScore,
        where: s.ad_id in ^ad_ids,
        distinct: s.ad_id,
        order_by: [asc: s.ad_id, desc: s.computed_at]
    )

  # merge by ad_id ...
end
```

## Why this works

- **Boundary preserved**: `Analytics` does NOT alias `Ads.Ad` or `Ads.AdAccount`. The cross-context call is an explicit public function on `Ads`.
- **Constant query envelope**: 4 queries total — `mc_ids lookup`, `filter_owned_ad_ids`, delivery aggregate, health DISTINCT ON. Invariant in N (proven by the `count_queries` test pattern).
- **Tenant scope owned by the right context**: `Ads.filter_owned_ad_ids/2` enforces the `MetaConnection.id` chain that `Ads.scope/2` already implements. Reuses, not duplicates.
- **Foreign ids silently dropped**: the result map is keyed by `Map.new(owned, ...)`, so foreign ids are absent from the result entirely (no sentinel/`nil` values that would leak ad existence).
- **Defense-in-depth UUID validation**: `Ecto.UUID.cast/1` filters malformed strings BEFORE the query runs, eliminating the need for a `rescue Ecto.Query.CastError` blanket (which would also swallow connection errors — anti-pattern documented separately).

## When to use

- Cross-context bulk aggregation where Context A needs to scope by entities owned by Context B.
- Any time you'd otherwise call `B.fetch_X(user, id)` in a loop before a `Context A` bulk query.
- Authorisation lists for bulk operations (e.g. "delete all of these ads if owned by user").

## When NOT to use

- Single-id paths — `B.fetch_X(user, id)` is already the right shape; don't introduce a list-of-one helper.
- When Context A's aggregate needs the FULL Ad struct (not just IDs). In that case add `B.list_owned_X(user, ids) :: [X.t()]` instead, with a `select([a], a)` body.

## Related

- `ecto/bulk-upsert-context-wrapper-keeps-repo-boundary-20260430.md` — bulk-write counterpart (Repo only called inside context).
- `ecto/rescue-too-broad-swallows-dbconnection-errors-20260427.md` — why pre-filtering with `Ecto.UUID.cast/1` is preferable to `rescue Ecto.Query.CastError`.
