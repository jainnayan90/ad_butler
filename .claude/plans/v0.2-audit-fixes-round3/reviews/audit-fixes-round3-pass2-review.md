# Audit Fixes Round 3 — Pass 2 Review (Post-Triage)

**Date:** 2026-04-27
**Agents:** elixir-reviewer, oban-specialist, iron-law-judge
**Verdict:** PASS WITH WARNINGS

⚠️ EXTRACTED FROM AGENT MESSAGES (agents could not write output files — see scratchpad)

---

## All Prior Findings: RESOLVED

| Finding | Status |
|---------|--------|
| B1 — shell logic inverted in check.unsafe_callers | ✅ RESOLVED |
| B2 — scan included legitimate internal callers | ✅ RESOLVED |
| W1 — rescue too broad, swallows DBConnection errors | ✅ RESOLVED |
| W2 — nil :ad_id via meta_id_map bracket lookup | ✅ RESOLVED |
| W3 — no signal when encode drops accounts | ✅ RESOLVED |
| W4 — get_ad_meta_id_map missing unsafe_ prefix | ✅ RESOLVED |
| W5 — Postgres timeout documentation | ✅ RESOLVED (comment added) |

---

## NEW WARNING — filter + Map.fetch! pairing is misleading

`lib/ad_butler/sync/insights_pipeline.ex:115,167`

The `Enum.filter(fn row -> Map.has_key?(meta_id_map, row.ad_id) end)` on line 115 guarantees the key exists by the time `Map.fetch!(meta_id_map, row.ad_id)` runs on line 167. The `fetch!` can never raise in practice — but the code reads as if it could crash, which may mislead future readers into adding unnecessary error handling or removing the filter. Consider collapsing to a single-pass `Enum.flat_map`:

```elixir
|> Enum.flat_map(fn row ->
  case Map.fetch(meta_id_map, row.ad_id) do
    {:ok, local_id} -> [normalise_row(row, local_id)]
    :error -> []
  end
end)
```

---

## SUGGESTION — InsightsConversionWorker.timeout/1 missing rationale comment

`lib/ad_butler/workers/insights_conversion_worker.ex:38`

`InsightsSchedulerWorker` has a three-line comment above `timeout/1` explaining the 6-minute value (DB transaction headroom). `InsightsConversionWorker` has the same value with no explanation — documentation inconsistency only, not a correctness issue.

---

## SUGGESTION — list_ad_accounts_internal/0 and stream_active_ad_accounts/0 lack unsafe_ prefix (PRE-EXISTING)

`lib/ad_butler/ads.ex:113,119`

Both functions bypass tenant scope but use `_internal` / no prefix rather than `unsafe_`. The `check.unsafe_callers` gate only catches `Ads.unsafe_` calls from the web layer — these two functions are invisible to the gate. Low urgency (sync pipeline uses them legitimately), but inconsistent with the naming convention established by `unsafe_get_ad_meta_id_map/1` and `unsafe_get_ad_account_for_sync/1`.

---

## SUGGESTION — DDL interpolation policy exception should be documented (PRE-EXISTING)

`lib/ad_butler/analytics.ex:38-40,122`

`safe_identifier!/1` mitigates injection risk adequately. PostgreSQL DDL doesn't support `$1` parameterized identifiers. A single inline comment at the call site documenting this as a reviewed exception would satisfy static analysis and Iron Law audits without any code change.

---

## Clean

- All Iron Law violations resolved
- `@impl Oban.Worker` annotations correct on both `perform/1` and `timeout/1`
- `Enum.split_with` pattern idiomatic and correct
- `unsafe_get_ad_meta_id_map/1` naming consistent with `unsafe_get_ad_account_for_sync/1`
- `check.unsafe_callers` gate correct and scoped properly
