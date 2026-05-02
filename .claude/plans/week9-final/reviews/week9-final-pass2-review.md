# Review: W9 Final Triage Fix-Up — Pass 2 (Post-Triage Verification)

**Date**: 2026-05-02
**Verdict**: **PASS WITH WARNINGS**
**Scope**: Verify the 9 pass-1 triage fixes landed correctly + catch any new issues introduced by them.

> All 3 review agents had Write denied to existing files. Findings extracted from agent return messages and captured verbatim into per-agent files.

---

## Pass-1 Findings — All Resolved ✅

Confirmed by all 3 agents:

- **W1** `analytics.ex:365` — bare `Ecto.UUID.load` match → `case` + nil-handling + flat_map drop
- **W2** `ads.ex:171` — too-broad rescue → removed; `Ecto.UUID.cast/1` pre-filter handles equivalent cases
- **W3** `simulate_budget_change_test.exs` — confidence-band boundaries (7-day → :medium, 21-day → :high) now tested
- **W4** `analytics_test.exs` — `count_queries/1` helper drains mailbox before each measurement; runs no longer perturb each other
- **S1** `server.ex:320-338` — `Enum.reduce` with per-key try/rescue; valid params survive unknown keys
- **S2** `compare_creatives.ex:79-85` — pattern-matched function heads on `%AdHealthScore{...}`
- **S3** `system_prompt.ex:51-54` — `render_ad_account_id(nil) → "(none)"` matches documented sentinel
- **S4** `ads.ex:160-187` — UUID pre-filter eliminates rescue-as-fallback
- **N1** `analytics.ex:309` — `if owned == []` replaces redundant `case`

Verification gate (re-run): compile clean, format clean, credo strict clean, custom checks clean, **549 tests / 0 failures**.

---

## New Findings

### WARNINGs (1)

#### W5 — `compare_creatives.ex:37` CompareCreatives per-ad `fetch_ad/2` N+1 (re-surfaced from pass-1)

- **Severity**: iron-law-judge proposes **BLOCKER**; orchestrator demotes to **WARNING** for triage (rationale below)
- **Code**: `Enum.map(&Ads.fetch_ad(user, &1))` — up to 5 sequential `Repo.get` calls, each re-running `Accounts.list_meta_connection_ids_for_user(user)` (~10 queries before the bulk Analytics call runs)
- **Why upgraded in pass-2**: `Ads.filter_owned_ad_ids/2` landed in pass-1 (W2/S4). The argument that "the helper returns IDs only and we need full Ad structs" no longer holds — adding `Ads.fetch_ads(user, ad_ids) :: [Ad.t()]` is a 4-line change that mirrors the existing `filter_owned_ad_ids/2` body with `select([a], a)`.
- **Why orchestrator demotes**: this finding existed in pass-1's iron-laws.md but was DROPPED from the pass-1 consolidated review (orchestrator error). The user did not have a chance to triage it. Surfacing it here as a fresh WARNING gives them that chance.
- **Fix sketch**:
  ```elixir
  # ads.ex
  @spec fetch_ads(User.t(), [binary()]) :: [Ad.t()]
  def fetch_ads(%User{} = user, ad_ids) when is_list(ad_ids) do
    valid = Enum.flat_map(ad_ids, fn id ->
      case Ecto.UUID.cast(id) do {:ok, u} -> [u]; :error -> [] end
    end)

    case valid do
      [] -> []
      ids ->
        mc_ids = Accounts.list_meta_connection_ids_for_user(user)
        Ad |> scope(mc_ids) |> where([a], a.id in ^ids) |> Repo.all()
    end
  end

  # compare_creatives.ex
  case Ads.fetch_ads(user, capped) do
    [] -> {:error, :no_valid_ads}
    ads -> ...
  end
  ```

### SUGGESTIONs (2)

| # | Source | Finding |
|---|---|---|
| S5 | elixir | `compare_creatives.ex:79-85` — `health_metric/2` non-exhaustive heads. Today only `:fatigue_score` and `:leak_score` are passed (call sites at lines 74-75), so safe. Adding a third metric atom at a call site without a matching head will raise `FunctionClauseError` at runtime. Suggest a `%AdHealthScore{} = score, key` catchall that logs and returns `nil`. |
| S6 | elixir | `analytics.ex:377` — `bin_to_uuid(_)` catchall returns `nil` silently. Schema drift (e.g. column type change) would silently drop rows. Logger.warning in catchall would surface this in observability. |

### Dismissed false-positives

- **security SU-1** — claimed `:unknown_keys` may not be in Logger allowlist. **Verified false** — present at [config/config.exs:119](../../../config/config.exs#L119) (added in P1-T4 of the original /phx:full).
- **elixir SUG1** (`filter_owned_ad_ids` `case` nesting) — code is clear; `if valid == []` is marginally tighter but not worth the churn. Dismissed as noise.

### PRE-EXISTING (out of scope)

- `ads.ex:904` (was line 890 pre-fixes) — `Logger.error` with string interpolation in message. Outside the W9 diff. Track separately.

---

## Spot-Check Summary (all PASS)

iron-law-judge confirmed:
- Repo isolation (Ads.filter_owned_ad_ids inside Ads context) ✅
- Tenant scoping (UUID pre-filter + scope join intact) ✅
- Structured logging (`unknown_keys` in allowlist) ✅
- No swallowed errors (DBConnection propagates from Repo.all) ✅
- Context boundary (CompareCreatives aliasing `AdHealthScore` for read-only struct match is acceptable) ✅

security-analyzer confirmed:
- SystemPrompt `nil → "(none)"` correct, no leak ✅
- `Ecto.UUID.cast/1` pre-filter equivalent to removed rescue ✅
- `normalise_params/1` no DoS vector ✅
- W3 boundary tests no leak surface ✅

---

## Recommendation

**PASS WITH WARNINGS.** One real WARNING (W5 re-surfaced N+1) plus 2 quality SUGGESTIONs.

Suggested next: triage W5 — either (a) accept and add `Ads.fetch_ads/2` now (small change, pairs naturally with the existing `filter_owned_ad_ids/2`), or (b) defer to a focused performance pass before W11 ships write tools (the N+1 is a small constant cost — 10 extra queries per `compare_creatives` call — not blocking but increasingly visible).
