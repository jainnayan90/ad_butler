# Week 7 Pass-5 Consolidated Review

**Diff scope:** 7 working-tree code files + CLAUDE.md (the pass-4 fixes from earlier this session, plus 2 new project rules).
**Reviewers:** elixir-reviewer, iron-law-judge, liveview-architect, testing-reviewer.
**Verdict:** **PASS WITH WARNINGS** — 2 NEW WARNINGS, 4 NEW SUGGESTIONS, 0 BLOCKERS.

> **Update (post-fix):** W-9, W-10, S-12, S-15 all addressed in the same session. S-13 (animate-pulse skeleton) and S-14 (stale-dropdown comment) deferred. Final state: 401 tests pass, credo clean.

All 9 pass-4 fixes verified to have landed correctly. The two warnings are *adjacency* gaps the new rules in CLAUDE.md surfaced:

1. A Logger `inspect/1` call in a different code path of `audit_scheduler_worker.ex` (the file I touched for S-11) was missed.
2. The disconnected-render test that the *new* CLAUDE.md rule mandates was not added.

Both flow directly from the institutional capture in `/phx:compound` — the rules now reach further than the original fix scope.

---

## NEW Findings — WARNINGS

### W-9: `Logger.error reason: inspect(reason)` survives in `audit_scheduler_worker.ex:63`

**File:** `lib/ad_butler/workers/audit_scheduler_worker.ex:63`.
**Source:** elixir-reviewer.

The W-4 fix targeted `creative_fatigue_predictor_worker.ex` only. The audit-scheduler `Oban.insert/1` error branch has the same anti-pattern in adjacent code I touched for S-11. Now codified as a violation by the new CLAUDE.md "Logging" rule.

```elixir
# current
Logger.error("audit_scheduler: unexpected insert error", reason: inspect(reason))

# fix
Logger.error("audit_scheduler: unexpected insert error", reason: reason)
```

### W-10: Missing disconnected-render test for `FindingDetailLive` (Iron Law #2 + new CLAUDE.md rule)

**File:** `test/ad_butler_web/live/finding_detail_live_test.exs`.
**Source:** elixir-reviewer + iron-law-judge + liveview-architect + testing-reviewer (all 4 flagged).

The W-8 fix added a placeholder render branch but no test covers it. CLAUDE.md "LiveView — Disconnected Render Must Not Be Blank" mandates a `Plug.Conn`/`html_response` test. `live/2` runs in connected mode and won't catch the regression.

```elixir
test "disconnected render shows loading placeholder + back link", %{conn: conn, user: user, finding: finding} do
  conn = log_in_user(conn, user)
  html = conn |> get(~p"/findings/#{finding.id}") |> html_response(200)
  assert html =~ "Loading finding"
  assert html =~ ~s(href="/findings")
end
```

---

## NEW Findings — SUGGESTIONS

### S-12: Duplicate "Back to Findings" link in `finding_detail_live.ex` placeholder

**File:** `lib/ad_butler_web/live/finding_detail_live.ex:75–84`.
**Source:** elixir-reviewer.

Same href in two `<div :if>` branches. Drift risk if the route changes. Extract to a private function component or a shared `<.link>`.

### S-13: Skeleton with `animate-pulse` for nicer loading UX

**File:** `lib/ad_butler_web/live/finding_detail_live.ex:73–80`.
**Source:** liveview-architect.

Replace plain "Loading finding…" text with `animate-pulse` placeholder divs that mirror the two-column grid shape. Prevents layout shift on slow connections. Optional polish.

### S-14: Inline comment on `:reload_on_reconnect` documenting the stale-dropdown trade

**File:** `lib/ad_butler_web/live/findings_live.ex` (handle_info clause).
**Source:** liveview-architect.

Add a one-line comment explaining the deliberate trade — ad_accounts list won't refresh until next reconnect — so future readers don't "fix" it back into `load_findings/1`.

### S-15: Telemetry query-counter test for the `:reload_on_reconnect` perf invariant

**File:** `test/ad_butler_web/live/findings_live_test.exs`.
**Source:** liveview-architect + testing-reviewer.

Without a test asserting `list_ad_accounts/1` is called once per session (not per filter), the S-9 perf claim is an untested contract. Recommend a `:telemetry` handler counting `[:ad_butler, :repo, :query]` events on the `ad_accounts` table, mount + 3 filter events, assert count = 1.

---

## Pass-4 Verification — All Resolved

| Fix | Verdict | Notes |
|-----|---------|-------|
| W-4 Logger inspect (fatigue worker) | PASS | All 3 calls use raw term |
| W-5 :ok contract @doc | PASS | Docstring explains raise-on-failure |
| W-6 `length(rows)` head pattern | PASS | Both `[]` and `[_]` covered by existing tests |
| W-7 `{:error, :insufficient}` tagged tuple | PASS | Caller `with` chain handles correctly |
| W-8 Disconnected-render placeholder | STRUCTURALLY PASS | Code right; test missing → W-10 |
| S-8 `Enum.zip_reduce/4` | PASS | |
| S-9 ad_accounts moved to `:reload_on_reconnect` | PASS | Pipeline order safe; perf claim untested → S-15 |
| S-10 Finding moduledoc | PASS | |
| S-11 Kill-switch comment | PASS | Note: same file has W-9 in different code |

---

## Per-agent reports

- [elixir-reviewer-pass5.md](elixir-reviewer-pass5.md)
- [iron-law-judge-pass5.md](iron-law-judge-pass5.md)
- [liveview-architect-pass5.md](liveview-architect-pass5.md)
- [testing-reviewer-pass5.md](testing-reviewer-pass5.md)
