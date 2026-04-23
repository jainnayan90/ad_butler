# Review: Week 2 — Blocker Fixes Follow-up

**Verdict: REQUIRES CHANGES**
**Date**: 2026-04-22
**Agents**: elixir-reviewer, oban-specialist, testing-reviewer
**Scope**: B1–B5 blocker fixes only (publisher.ex, fetch_ad_accounts_worker.ex, factory.ex)

---

## B1–B5 Fix Verification

| Fix | Verdict | Notes |
|-----|---------|-------|
| B1: Publisher lazy connect | ✅ Correct | `send(self(), :connect)` in init, guard on nil channel |
| B2: Channel monitoring | ✅ Correct | Both conn_ref + channel_ref stored and demonitored |
| B3: Propagate publish failures | ✅ Correct (with gap) | `with/else` propagates errors; see NW2 below |
| B4: Unique constraint | ✅ Correct | No additional migration needed; Oban v14 covers it |
| B5: Factory consistency | ⚠️ Partial | Default path fixed; single-override callers still inconsistent |

---

## NEW BLOCKERS

### [NB1] `ad_set_factory` single-override callers still produce inconsistent state
**File**: `test/support/factory.ex:50-62`
**Agent**: testing-reviewer

The B5 fix correctly ensures the default factory build is consistent. However, ExMachina merges caller overrides AFTER the factory body runs, replacing only the explicitly named field:

- `insert(:ad_set, ad_account: aa)` → `ad_set.ad_account_id = aa.id` but `campaign.ad_account_id` points to the factory-built account, not `aa`.
- `insert(:ad_set, campaign: c)` → `ad_set.campaign_id = c.id` but `ad_set.ad_account_id` points to the factory-built account, not `c.ad_account_id`.

Current call sites in `ads_test.exs` always pass both fields via `insert_ad_set_for/2`, so no tests fail today. But the factory is a trap for any future caller.

**Fix**: Use the `attrs` parameter pattern in ExMachina:
```elixir
def ad_set_factory(attrs) do
  ad_account = attrs[:ad_account] || build(:ad_account)
  campaign   = attrs[:campaign]   || build(:campaign, ad_account: ad_account)

  struct(AdSet, %{
    ad_account: ad_account,
    campaign: campaign,
    meta_id: sequence(:ad_set_meta_id, &"adset_#{100 + &1}"),
    name: sequence(:ad_set_name, &"Ad Set #{&1}"),
    status: "ACTIVE",
    raw_jsonb: %{}
  })
end
```

---

### [NB2] `ad_factory` has the identical structural problem
**File**: `test/support/factory.ex:64-75`
**Agent**: testing-reviewer

`ad_factory` builds `ad_set = build(:ad_set)` then uses `ad_set.ad_account`. Callers passing `insert(:ad, ad_set: s)` get `ad.ad_account_id` pointing to the factory's ad_account, not `s.ad_account_id`. The test at line 240 masks this by explicitly passing both `ad_account:` and `ad_set:`.

**Fix**: Apply same `attrs`-based pattern:
```elixir
def ad_factory(attrs) do
  ad_set    = attrs[:ad_set]      || build(:ad_set)
  ad_account = attrs[:ad_account] || ad_set.ad_account

  struct(Ad, %{ad_account: ad_account, ad_set: ad_set, ...})
end
```

---

## NEW WARNINGS

### [NW1] `AMQP.Channel.open/1` failure orphans TCP connection
**File**: `lib/ad_butler/messaging/publisher.ex:60`
**Agent**: elixir-reviewer

`{:ok, channel} = AMQP.Channel.open(conn)` is a bare match. If channel open fails, the GenServer crashes with `MatchError`. The already-opened `conn` is never closed — orphaned TCP connection until broker heartbeat timeout. Rare but correctness gap.

**Fix**: Wrap in `case`, call `AMQP.Connection.close(conn)` on error before scheduling retry.

---

### [NW2] `Jason.encode!/1` raises — not caught by `with/else`
**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:46`
**Agent**: oban-specialist

`with/else` pattern-matches on return values; it cannot catch exceptions. If `account["id"]` is non-serialisable, Oban catches the exception and retries silently — bypassing the `Logger.warning` path. Oban still retries correctly, but the warning log is lost.

**Fix**: Use `Jason.encode/1` as a `with` clause:
```elixir
payload = Jason.encode!(%{...})  # currently

# Fix:
{:ok, payload} <- Jason.encode(%{ad_account_id: account["id"], sync_type: "full"}),
```

---

### [NW3] Oban unique `:completed` state blocks re-trigger within 5 min
**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:6`
**Agent**: elixir-reviewer

`unique: [period: 300, ...]` inherits Oban's default `states: [:scheduled, :available, :executing, :retryable, :completed]`. A job that completed successfully within 5 minutes blocks re-insertion silently. If a webhook or manual trigger needs to re-sync right after a successful run, the job is dropped with no signal.

**Recommendation**: If re-triggering after success is valid, add `states: [:scheduled, :available, :executing, :retryable]` (exclude `:completed`). If 5-min rate-limit is intentional, document it.

---

### [NW4] `get_meta_connection!/1` wastes all 5 retry attempts on deleted connection
**File**: `lib/ad_butler/workers/fetch_ad_accounts_worker.ex:13`
**Agent**: oban-specialist (pre-existing, but relevant)

If the MetaConnection is deleted between scheduling and execution, the bang raises `Ecto.NoResultsError` and Oban retries 5 times before discarding. Should return `{:cancel, "meta_connection_not_found"}` instead.

---

## SUGGESTIONS

| # | Finding |
|---|---------|
| S1 | `publisher.ex` — `AMQP.Channel.open` failure path also missing retry schedule; fix together with NW1 |
| S2 | `ad_factory` — No test exercises single-override path; add one after NB2 fix |
| S3 | `fetch_ad_accounts_worker.ex` — Add `def timeout(_job), do: :timer.minutes(2)` to prevent Oban default timeout on large account lists |
| S4 | `insert_ad_set_for/2` in `DataCase` (shared) — Promote to prevent other test modules from using the factory with single overrides |

---

## Pre-existing (not introduced by blocker fixes)

- `[W]` W1–W10 from prior review deferred — unchanged
