# Code Review: week-2-review-fixes-2 — Elixir Reviewer

⚠️ EXTRACTED FROM AGENT MESSAGE (agent Write access denied)

**Status**: PASS WITH WARNINGS
**Issues**: 2 warnings · 2 suggestions

---

## Warnings

### W1 — `Oban.insert_all/1` return type assumption (audit_scheduler_worker.ex:31–34)

`Oban.insert_all/1` returns a flat list of jobs/changesets, **not** `{:ok, _} | {:error, _}` tuples. The filter:

```elixir
failed = Enum.filter(results, &match?({:error, _}, &1))
```

will always produce `[]` because no element is ever a tagged tuple. Failed inserts surface as invalid/conflict changesets in the returned list.

Safer approach:
```elixir
results = Oban.insert_all(valid)
unless length(results) == length(valid) do
  Logger.error("audit_scheduler: insert_all returned fewer jobs than submitted",
    submitted: length(valid), returned: length(results))
end
```

### W2 — Float arithmetic in `check_bot_traffic/3` inconsistent with fixed heuristics (budget_leak_auditor_worker.ex)

`check_cpa_explosion` and `check_placement_drag` were fixed to integer multiplication, but `check_bot_traffic` still uses float division for `ctr` and `conversion_rate`. Not a money bug (values not stored), but inconsistent.

### W3 — `async: false` comment reason is inaccurate in worker test files

The comment says "REFRESH MATERIALIZED VIEW cannot run CONCURRENTLY inside a sandbox transaction" but the calls don't use CONCURRENTLY. The real reason: shared mutable state — concurrent processes would see each other's `insights_daily` rows and mat-view data.

---

## Suggestions

### S1 — `handle_params/3` UUID validation is format-only (findings_live.ex)

`Ecto.UUID.cast/1` validates format, not ownership. Not a security bug — `scope_findings/2` join through `AdAccount` filtered by MetaConnection IDs enforces ownership. A comment clarifying this implicit defense would help future readers.

### S2 — `with` guard in insights_pipeline.ex is correct

`normalised when not is_nil(normalised.date_start) <- normalise_row(row, local_id)` correctly replaces the anti-pattern. No action needed.

---

## Pre-existing (Not In This Diff)

- W5 PERSISTENT: `Task.start/1` unsupervised
- W6 PERSISTENT: `/health/readiness` no rate limiting
- B2 PERSISTENT: `/app/bin/migrate` missing
- B3 PERSISTENT: Docker ARG not exported as ENV
