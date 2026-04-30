# Elixir Review — Week 7 Audit (Pass 4)

**Verdict:** PASS WITH WARNINGS — 3 NEW WARNINGS, 4 NEW SUGGESTIONS, 0 BLOCKERS

> Note: written by parent after agent returned findings inline (it lacked Write permission).

---

## Pass-3 Resolutions Confirmed

- **B-1**: `clicks = 80 - (6 - d) * 10` formula still present at 6 test sites; sequence is correct (declining → negative slope → fires).
- **W-2**: `AuditHelpers.dedup_constraint_error?/1` is the sole implementation; both workers delegate.
- **W-3**: Strict `== %{"snapshots" => []}` assertion confirmed at `test/ad_butler/ads_test.exs:472`.

No regressions.

---

## NEW Findings

### WARNING

**W-4 (elixir): `length/1` walks the whole list in `compute_ctr_slope/2`**

`lib/ad_butler/analytics.ex:268`. The `case length(rows) < 2` branch O(n)-traverses the full row list before `Enum.map`. Replace with head pattern matching:

```elixir
case rows do
  [] -> 0.0
  [_] -> 0.0
  ctrs -> ...
end
```

**W-5 (elixir): `avg_cpm/1` returns bare `:insufficient` not `{:error, :insufficient}`**

`lib/ad_butler/analytics.ex:356`. Violates the tagged-tuple convention (CLAUDE.md "Function Design — Return `{:ok, value} | {:error, reason}`"). The bare atom silently bypasses the `else _ -> nil` chain in a way future handlers could miss.

**W-6 (elixir): `handle_params` no-op on disconnected render leaves `@finding` nil**

`lib/ad_butler_web/live/finding_detail_live.ex:28`. The disconnected static render produces a blank page when `@finding` is nil. Either assign a loading placeholder or `push_navigate` to `/findings` on the else branch.

### SUGGESTION

**S-8 (elixir): Use `Enum.zip_reduce/4` instead of `Enum.zip |> Enum.reduce`**

`lib/ad_butler/analytics.ex:373`. Eliminates intermediate tuple list.

**S-9 (elixir): `findings_live.ex:210` re-queries `Ads.list_ad_accounts/1` on every filter/page click**

Load once in `mount` after `connected?/1` and assign; reuse on subsequent `handle_params`.

**S-10 (elixir): `finding.ex:3` `@moduledoc` mentions only "budget leak" — `creative_fatigue` is now a valid kind**

Trivial documentation drift.

**S-11 (elixir): Kill-switch `Application.get_env` should carry an inline comment marking it as intentionally runtime**

`lib/ad_butler/workers/audit_scheduler_worker.ex:35`. Prevents future refactor extracting it to a `@fatigue_enabled` module attribute (which would freeze at compile time and break the toggle).

---

## Pre-existing (one-liners)

(None outside diff scope flagged.)
