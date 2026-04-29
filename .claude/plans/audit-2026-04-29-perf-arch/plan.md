# Plan: Audit Fixes — Performance + Architecture

**Source**: `.claude/audit/summaries/project-health-2026-04-29.md`
**Date**: 2026-04-29
**Scope**: CRITICAL + HIGH findings only. Index, test, and deps fixes deferred to follow-up.

---

## Context

`BudgetLeakAuditorWorker` has two N+1 patterns introduced in the auditor feature:
1. `insert_health_scores/2` calls `Repo.insert` once per ad (via `Analytics.insert_ad_health_score/1`)
2. `maybe_emit_finding/3` calls `Analytics.get_unresolved_finding/2` once per `{ad_id, kind}` pair

Three cross-context boundary violations also identified:
1. `Analytics.Finding` and `Analytics.AdHealthScore` use `belongs_to` pointing into `Ads`/`Accounts` schemas
2. `Analytics.scope_findings/2` directly JOINs `AdButler.Ads.AdAccount` in an Ecto query
3. `Ads.upsert_ad_account/2` pattern-matches on `%Accounts.MetaConnection{}` struct

---

## Phase 1: Performance — Batch DB Operations

### - [x] [P1-T1][ecto] Batch `insert_health_scores/2` with `Repo.insert_all` — bulk_insert_health_scores/1 added to Analytics; worker uses Enum.map + single insert_all

**Current**: `insert_health_scores/2` in `budget_leak_auditor_worker.ex:79` iterates `fired_by_ad` and calls `Analytics.insert_ad_health_score/1` (one `Repo.insert` per ad). 500 ads = 500 round-trips.

**Fix**:

1. Add `Analytics.bulk_insert_health_scores/1` to `lib/ad_butler/analytics.ex`:

```elixir
@doc "Bulk-upserts health scores. DB errors raise; Oban retries the job."
@spec bulk_insert_health_scores([map()]) :: :ok
def bulk_insert_health_scores([]), do: :ok
def bulk_insert_health_scores(entries) do
  Repo.insert_all(
    AdHealthScore,
    entries,
    on_conflict: {:replace, [:leak_score, :leak_factors, :inserted_at]},
    conflict_target: [:ad_id, :computed_at]
  )
  :ok
end
```

2. Replace `insert_health_scores/2` in the worker:

```elixir
defp insert_health_scores(fired_by_ad, _ad_account_id) when map_size(fired_by_ad) == 0,
  do: :ok

defp insert_health_scores(fired_by_ad, _ad_account_id) do
  bucket = six_hour_bucket()
  now = DateTime.utc_now()

  entries =
    Enum.map(fired_by_ad, fn {ad_id, fired_kinds} ->
      score = compute_leak_score(fired_kinds)
      %{
        id: Ecto.UUID.generate(),
        ad_id: ad_id,
        computed_at: bucket,
        leak_score: Decimal.new(score),
        leak_factors: Map.new(fired_kinds, &{&1, Map.get(@weights, &1, 0)}),
        inserted_at: now
      }
    end)

  Analytics.bulk_insert_health_scores(entries)
end
```

Note: `Decimal.new(score)` ensures the decimal column receives a `Decimal`, not a bare integer (Repo.insert_all bypasses Ecto type casting).

**Verify**: `mix compile --warnings-as-errors` then run `mix test test/ad_butler/workers/budget_leak_auditor_worker_test.exs`.

---

### - [x] [P1-T2][ecto] Bulk-load open findings before `maybe_emit_finding/3` loop — list_open_finding_keys/1 added; open_findings MapSet threaded through run_all_heuristics→run_heuristics→apply_check→maybe_emit_finding/4

**Current**: `maybe_emit_finding/3` in `budget_leak_auditor_worker.ex:346` calls `Analytics.get_unresolved_finding(ad_id, kind)` — one SELECT per `{ad_id, kind}` pair. With 5 heuristics × N ads = 5N extra queries per audit run.

**Fix**:

1. Add `Analytics.list_open_finding_keys/1` to `lib/ad_butler/analytics.ex`:

```elixir
@doc "Returns a MapSet of {ad_id, kind} tuples for all open (unresolved) findings for the given ad_ids."
@spec list_open_finding_keys([binary()]) :: MapSet.t()
def list_open_finding_keys([]), do: MapSet.new()
def list_open_finding_keys(ad_ids) do
  Repo.all(
    from f in Finding,
      where: f.ad_id in ^ad_ids and is_nil(f.resolved_at),
      select: {f.ad_id, f.kind}
  )
  |> MapSet.new()
end
```

2. Load the MapSet in `run_all_heuristics/5` and thread it through call chain:

```elixir
# run_all_heuristics/5 → /6
defp run_all_heuristics(grouped, ad_account_id, ad_set_map, stalled_ad_sets, baselines) do
  ad_ids = Map.keys(grouped)
  open_findings = Analytics.list_open_finding_keys(ad_ids)

  Enum.reduce_while(grouped, {:ok, %{}}, fn {ad_id, rows}, {:ok, acc} ->
    case run_heuristics(ad_id, rows, ad_account_id, ad_set_map, stalled_ad_sets, baselines, open_findings) do
      {:ok, fired} -> {:cont, {:ok, Map.put(acc, ad_id, fired)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end
```

3. Thread `open_findings` into `run_heuristics/7`:
```elixir
defp run_heuristics(ad_id, rows, ad_account_id, ad_set_map, stalled_ad_sets, baselines, open_findings) do
  ...
  # Pass open_findings to maybe_emit_finding/4
end
```

4. Replace `maybe_emit_finding/3` with `/4`:
```elixir
defp maybe_emit_finding(ad_id, kind, attrs, open_findings) do
  if MapSet.member?(open_findings, {ad_id, kind}) do
    :skipped
  else
    # existing create_finding logic (DB index guards the race window)
    ...
  end
end
```

Note: the partial unique index `findings_ad_id_kind_unresolved_index` remains the authoritative dedup guard for concurrent workers. The MapSet is a performance optimization only.

**Verify**: `mix compile --warnings-as-errors` then run `mix test test/ad_butler/workers/budget_leak_auditor_worker_test.exs`.

---

## Phase 2: Architecture — Cross-Context Boundary Cleanup

### - [x] [P2-T1][ecto] Remove cross-context `belongs_to` from `Analytics` schemas — replaced with plain field :ad_id/:ad_account_id/:acknowledged_by_user_id :binary_id in both schemas

**Location**: `lib/ad_butler/analytics/finding.ex:16-19`, `lib/ad_butler/analytics/ad_health_score.ex:15`

`belongs_to` macros both define the FK field AND create an Ecto association to the foreign schema. Only the FK field is needed; the association creates a hard compile-time dependency into other contexts.

**In `lib/ad_butler/analytics/finding.ex`**: Replace:
```elixir
belongs_to :ad, AdButler.Ads.Ad
belongs_to :ad_account, AdButler.Ads.AdAccount
belongs_to :acknowledged_by, AdButler.Accounts.User, foreign_key: :acknowledged_by_user_id
```
With:
```elixir
field :ad_id, :binary_id
field :ad_account_id, :binary_id
field :acknowledged_by_user_id, :binary_id
```

**In `lib/ad_butler/analytics/ad_health_score.ex`**: Replace:
```elixir
belongs_to :ad, AdButler.Ads.Ad
```
With:
```elixir
field :ad_id, :binary_id
```

The FK fields `:ad_id`, `:ad_account_id`, `:acknowledged_by_user_id` already appear in `@content_fields` / `@required` / changesets — they continue to work unchanged.

**Verify**: `mix compile --warnings-as-errors` (catches any `finding.ad` association access that would now break).

---

### - [x] [P2-T2][ecto] Refactor `Analytics.scope_findings/2` to avoid direct `AdAccount` join — list_ad_account_ids_for_mc_ids/1 added to Ads; scope_findings uses Ads.list_ad_account_ids_for_mc_ids + where clause; factory and test helpers updated to use ad_id/ad_account_id fields

**Location**: `lib/ad_butler/analytics.ex:235-242`

**Fix**:

1. Add `Ads.list_ad_account_ids_for_mc_ids/1` to `lib/ad_butler/ads.ex`:

```elixir
@doc "Returns all ad account IDs belonging to the given MetaConnection IDs."
@spec list_ad_account_ids_for_mc_ids([binary()]) :: [binary()]
def list_ad_account_ids_for_mc_ids([]), do: []
def list_ad_account_ids_for_mc_ids(mc_ids) do
  Repo.all(from aa in AdAccount, where: aa.meta_connection_id in ^mc_ids, select: aa.id)
end
```

2. Replace `scope_findings/2` in `lib/ad_butler/analytics.ex`:

```elixir
defp scope_findings(queryable, %User{} = user) do
  mc_ids = Accounts.list_meta_connection_ids_for_user(user)
  ad_account_ids = Ads.list_ad_account_ids_for_mc_ids(mc_ids)
  where(queryable, [f], f.ad_account_id in ^ad_account_ids)
end
```

3. Remove `alias AdButler.Ads.AdAccount` from `analytics.ex` (no longer needed).
   Add `alias AdButler.Ads` if not already present.

**Verify**: `mix compile --warnings-as-errors` then `mix test test/ad_butler/analytics_test.exs` (tenant isolation tests must still pass).

---

### - [x] [P2-T3][ecto] Fix `Ads.upsert_ad_account/2` to accept `meta_connection_id` binary — signature changed to is_binary guard; FetchAdAccountsWorker passes connection.id; ads_test updated

**Location**: `lib/ad_butler/ads.ex:158-161`

Current signature:
```elixir
def upsert_ad_account(%AdButler.Accounts.MetaConnection{} = connection, attrs)
```

Callers pass the full struct only to extract `connection.id`. Replace with:
```elixir
def upsert_ad_account(meta_connection_id, attrs) when is_binary(meta_connection_id)
```

Update the body to use `meta_connection_id` directly instead of `connection.id`.

Update all callers — grep `upsert_ad_account` to find them and update to pass `connection.id` (or `meta_connection_id` if the ID is already available).

**Verify**: `mix compile --warnings-as-errors`.

---

## Phase 3: Verification

### - [x] [P3-T1] Full suite + credo — 321 tests, 0 failures, 0 credo warnings

```bash
mix precommit
```

All 321 tests must pass. Zero credo warnings.

---

## Deferred (track separately)

- Missing indexes: `campaigns(ad_account_id)`, `ad_sets(ad_account_id)`, `findings(ad_account_id, inserted_at DESC)`
- Test coverage: `paginate_meta_connections/2`, `list_expiring_meta_connections/2`, partition functions
- Dep scoping: `broadway_rabbitmq only: :prod`, `ex_machina only: :test`
- `AuthControllerTest` Mox global fix
- `FindingsLive.load_findings` re-queries `list_ad_accounts` on every page change
- Unbounded `list_ad_sets/2` and `list_ads/2`
