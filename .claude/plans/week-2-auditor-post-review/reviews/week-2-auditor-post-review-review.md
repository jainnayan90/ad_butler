# Review: week-2-auditor-post-review

**Verdict: REQUIRES CHANGES**
5 agents ran · 3 blockers · 7 warnings · 6 suggestions

---

## Blockers (Must Fix)

### B1 — `Oban.insert_all/1` return type misunderstood — failure detection broken
`lib/ad_butler/workers/audit_scheduler_worker.ex:23-33`

`Oban.insert_all/1` in Oban 2.18 returns `[Job.t()]` — a flat list of structs, **not** `[{:ok, job} | {:error, _}]`. The `Enum.filter(results, &match?({:error, _}, &1))` check always returns `[]`. Invalid changesets are silently dropped.

**Fix:**
```elixir
{valid, invalid} = Enum.split_with(changesets, &(&1.valid?))
Enum.each(invalid, &Logger.error("audit_scheduler: invalid job changeset", errors: &1.errors))
Oban.insert_all(valid)
```

### B2 — `FindingDetailLive.handle_params/3` runs DB queries on disconnected mount
`lib/ad_butler_web/live/finding_detail_live.ex:23-34`

Both `Analytics.get_finding!` and `Analytics.get_latest_health_score` run unconditionally — on HTTP render AND WebSocket connect. Every page view costs 2 DB queries instead of 1. `FindingsLive` already has the correct pattern.

**Fix:** Wrap body with `if connected?(socket), do: ..., else: {:noreply, socket}`.

### B3 — `get_finding!/2` raises uncaught from `handle_params/3` — no graceful redirect
`lib/ad_butler_web/live/finding_detail_live.ex:25`

A bad or expired `id` in the URL raises `Ecto.NoResultsError` inside the LiveView process — crash instead of redirect. Violates CLAUDE.md: "Never raise in the happy path."

**Fix:** Add `Analytics.get_finding/2 → {:ok, finding} | {:error, :not_found}` and handle the error with `push_navigate(socket, to: ~p"/findings")` + flash.

---

## Warnings

### W1 — `with true <-` misuse in `check_cpa_explosion` and `check_placement_drag`
`budget_leak_auditor_worker.ex:174, 242`

`with true <- condition` turns `with` into a disguised `cond` and makes the `else _ -> :skip` clause opaque. Use explicit `if` guards.

Also in `check_placement_drag`: plain `=` assignments (`cpas = Enum.map(...)`) inside `with` arms — these belong in the `do` body. And `when length(placements) >= 2` is O(n) — use `[_, _ | _] = placements` instead.

### W2 — `get_latest_health_score/1` not prefixed `unsafe_`
`lib/ad_butler/analytics.ex:122-136`

Documented "UNSAFE — callers must verify ownership" but not named `unsafe_` unlike all equivalent `Ads` module functions. Rename to `unsafe_get_latest_health_score/1`.

### W3 — `insert_health_scores` is NOT idempotent — retries produce duplicate rows
`budget_leak_auditor_worker.ex:71`

`insert_ad_health_score/1` is append-only. On Oban retry (max_attempts: 3), ads processed before the failure get duplicate health score rows.

**Fix:** Upsert with `on_conflict: {:replace, [:leak_score, :leak_factors]}, conflict_target: [:ad_id, :computed_at]` (requires rounding `computed_at` to a 6h window).

### W4 — `handle_info(:reload_on_reconnect)` duplicates `handle_params` logic
`findings_live.ex:111`

Both callbacks build identical opts and call `paginate_findings` + `list_ad_accounts`. Extract to a private `load_findings(socket)` helper.

### W5 — `_ = Ads` unused alias in `FindingDetailLive`
`finding_detail_live.ex` — Remove the alias; dead-assignment suppression is a code smell.

### W6 — "Growing reach" skip test may pass vacuously
`budget_leak_auditor_worker_test.exs:90`

The `REFRESH MATERIALIZED VIEW` in `setup` runs before `insert_insight`, so the 30d view is empty. The worker sees no insights data and trivially skips before reaching the reach-uplift guard. The test does not validate the intended guard logic.

---

## Suggestions

- **CT1** — No cross-tenant `acknowledge` event test — tenant isolation only covers mount path
- **CT2** — `acknowledge_finding(user_b, finding_a.id)` cross-tenant denial untested in `analytics_test.exs`
- **O4** — Remove redundant `unique:` runtime override in `AuditSchedulerWorker.new/2`
- **WT2** — Uniqueness scheduler test overrides worker's declared config — call `new/1` without opts
- **WT5** — Stalled learning boundary exactly 7 days untested (only `days_ago = 8` covered)
- **S1** — Add CI grep or Credo check preventing `lib/ad_butler_web/**` from calling `unsafe_*` functions

---

## Clean / Passing

- Context boundary enforced: workers never call `Repo` directly
- No `:float` for money — `:decimal` for scores, `:integer` cents for spend
- Both migrations reversible
- DaisyUI component classes absent — plain Tailwind utilities only
- `FindingsLive` correctly guards behind `connected?(socket)`
- Streams used for findings list with pagination
- Tenant isolation: scoped queries through `scope_findings/2`
- Oban workers use string keys, have `unique:` and `max_attempts:` set
