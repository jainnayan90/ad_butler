# Elixir Review — week-2-auditor-findings
⚠️ EXTRACTED FROM AGENT MESSAGE (agent had no Write permission)

## Status: REQUIRES CHANGES — 1 BLOCKER, 5 WARNINGs, 3 SUGGESTIONs

---

## BLOCKER

### `upsert_ad_health_score` return value silently discarded
**File**: `lib/ad_butler/workers/budget_leak_auditor_worker.ex:66`
`Enum.each` discards `{:ok, _} | {:error, _}`. A DB failure causes the job to return `:ok` and Oban never retries.
**Fix**: Collect results with `Enum.map`, detect any `{:error, _}`, and return `{:error, reason}`.

---

## WARNINGs

### `with true <- boolean` non-idiomatic
**File**: `budget_leak_auditor_worker.ex:226,228`
`with true <- conversions_3d > 0` and `with true <- baseline != nil` are non-idiomatic. The nil check is better absorbed via pattern matching on `{:ok, %{cpa_cents: baseline_cpa}}` directly.

### `upsert_ad_health_score` name contradicts behaviour
**File**: `lib/ad_butler/analytics.ex:117`
Always INSERTs (append-only), never upserts. Rename to `insert_ad_health_score` to match `@moduledoc` on `AdHealthScore`.

### `@doc false` on `defp` is a no-op
**File**: `budget_leak_auditor_worker.ex:375`
`@doc false` only affects public `def`. Remove it.

### `_ = Ads` dead-code stub
**File**: `lib/ad_butler_web/live/finding_detail_live.ex:182`
Keeping an alias alive with `_ = Ads` is a smell. Remove both alias and stub; restore when actually used.

### Ad accounts dropdown cached with fragile assign guard
**File**: `lib/ad_butler_web/live/findings_live.ex:54-58`
`case socket.assigns.ad_accounts_list do [] -> load ...` is fragile. Use `assign_new(:ad_accounts_list, fn -> Ads.list_ad_accounts(current_user) end)` in mount instead.

---

## SUGGESTIONs

### `run_heuristics` uses imperative reassignment
**File**: `budget_leak_auditor_worker.ex:82-136`
Five sequential `fired = case ...` blocks. A single pipeline collecting `{:emit, attrs}` tuples is easier to extend.

### Duplicate private helpers across LiveViews
`severity_badge_class/1` and `kind_label/1` are copy-pasted between `FindingsLive` and `FindingDetailLive`. Extract to a shared `AdButlerWeb.FindingComponents` module.

### Manual index SQL in migration not using Ecto macro
**File**: `priv/repo/migrations/20260427000001_create_ad_health_scores.exs:17-20`
`execute/2` provides drop SQL manually. `create index(:ad_health_scores, [:ad_id, :computed_at], order_by: [computed_at: :desc])` would be fully reversible without manual SQL.
