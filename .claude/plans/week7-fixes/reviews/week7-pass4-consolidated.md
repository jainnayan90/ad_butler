# Week 7 Audit — Pass 4 Consolidated Review

**Plan:** [.claude/plans/week7-fixes/plan.md](../plan.md)
**Code under review:** Commit `549e2f0` (week 7 audit/fatigue + week7-fixes folded in)
**Reviewers:** elixir-reviewer, oban-specialist, iron-law-judge
**Verdict:** **PASS WITH WARNINGS** — 5 NEW WARNINGS, 4 NEW SUGGESTIONS, 0 BLOCKERS

Pass-3 resolutions (B-1, W-2, W-3) confirmed still in place. Two suggestions deferred from pass-3 (S-6 arity asymmetry, S-7 tenant-test precondition pin) carry forward.

---

## NEW Findings — WARNINGS

### W-4: `Logger.error reason: inspect(...)` violates Iron Law #8 (structured logging)

**File:** `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex` lines ~236 and ~355.
**Source:** iron-law-judge + oban-specialist (both agreed; iron-law-judge wins on deconfliction).

Both `Logger.error` calls coerce terms to strings via `inspect/1`, breaking structured log aggregation in Loki/Datadog. CLAUDE.md mandates raw KV.

**Fix:** `reason: reason` directly. For `%Ecto.Changeset{}` use `reason: changeset.errors`.

### W-5: `append_quality_ranking_snapshots/2` returns unconditional `:ok`

**File:** `lib/ad_butler/ads.ex:542-563`.
**Source:** iron-law-judge.

`SQL.query!` raises on failure so the exception does propagate — not a silent swallow — but callers cannot distinguish "nothing to write" from "write succeeded." Either document the `:ok` convention with a `@doc` note explaining the raise-on-failure contract, or return the `SQL.query!` result tuple.

### W-6: `length(rows) < 2` walks the full list in `compute_ctr_slope/2`

**File:** `lib/ad_butler/analytics.ex:268`.
**Source:** elixir-reviewer.

`length/1` is O(n). Replace with head pattern matching:
```elixir
case rows do
  [] -> 0.0
  [_] -> 0.0
  ctrs -> ...
end
```

### W-7: `avg_cpm/1` returns bare `:insufficient` instead of `{:error, :insufficient}`

**File:** `lib/ad_butler/analytics.ex:356`.
**Source:** elixir-reviewer.

Violates the project's tagged-tuple convention (CLAUDE.md "Function Design"). Future handlers may miss the bare-atom path.

### W-8: `FindingDetailLive.handle_params` no-op blanks `@finding` on disconnected render

**File:** `lib/ad_butler_web/live/finding_detail_live.ex:28`.
**Source:** elixir-reviewer.

The disconnected static render produces a blank page when `@finding` is nil. Either assign a loading placeholder or `push_navigate` to `/findings` on the disconnected else branch.

---

## NEW Findings — SUGGESTIONS

### S-8: Use `Enum.zip_reduce/4` instead of `Enum.zip |> Enum.reduce`

**File:** `lib/ad_butler/analytics.ex:373`. Eliminates intermediate tuple list.

### S-9: `findings_live.ex:210` re-queries `Ads.list_ad_accounts/1` per filter/page click

Load once in `mount/3` after `connected?/1`, assign, and reuse on subsequent `handle_params/3`.

### S-10: `finding.ex:3` `@moduledoc` mentions only "budget leak" — `creative_fatigue` is now a valid kind

Trivial documentation drift.

### S-11: Kill-switch `Application.get_env` should carry an inline comment marking it as intentionally runtime

**File:** `lib/ad_butler/workers/audit_scheduler_worker.ex:35`.
**Source:** elixir-reviewer + oban-specialist (deduped).

Prevents future refactor extracting it to a `@fatigue_enabled` module attribute, which would freeze at compile time and break the toggle.

---

## Carried Forward From Pass-3 (still deferred)

- **S-6:** `handle_create_result/N` arity asymmetry between leak vs fatigue worker — intentional, deferred.
- **S-7:** Tenant-isolation test could pin firing-precondition explicitly — preventive, deferred.

---

## Confirmed Still-Resolved

- **B-1** (pass-2): Tenant-isolation test fixture firing data — formula `clicks = 80 - (6 - d) * 10` produces a declining sequence; heuristic fires.
- **W-2** (pass-2): `AuditHelpers.dedup_constraint_error?/1` is the sole canonical implementation.
- **W-3** (pass-2): Strict `== %{"snapshots" => []}` assertion at `ads_test.exs:472`.
- **N+1 elimination** (Iron Law #15): `unnest()` UPDATE — single SQL statement.
- **Tenant scope** (Iron Law #7): `paginate_findings`, `get_finding`, `acknowledge_finding`.
- **Repo boundary** (Iron Law #6): Repo only inside contexts.
- **Idempotency under retry**: column-isolated `on_conflict` on `(ad_id, computed_at)` — verified safe across leak + fatigue concurrent writes.
- **No `String.to_atom/1`** in `lib/` (Iron Law #7).
- **Migration reversibility** (Iron Law #14).

---

## Per-agent reports

- [elixir-reviewer-pass4.md](elixir-reviewer-pass4.md)
- [oban-specialist-pass4.md](oban-specialist-pass4.md)
- [iron-law-judge-pass4.md](iron-law-judge-pass4.md)
