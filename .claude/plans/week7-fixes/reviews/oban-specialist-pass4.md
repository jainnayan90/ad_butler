# Oban Review — Week 7 (Pass 4)

**Verdict:** PASS WITH WARNINGS — 1 WARNING, 2 SUGGESTIONS, 0 BLOCKERS

> Note: written by parent after agent returned findings inline.

---

## NEW Findings

### WARNING

**W-4: `inspect/1` on error reasons in structured Logger calls — violates CLAUDE.md KV-logging rule**

`lib/ad_butler/workers/creative_fatigue_predictor_worker.ex` lines 236 and 365.

Both `Logger.error` calls pass `reason: inspect(reason)` — a string — instead of the raw term. CLAUDE.md mandates structured KV metadata. Stringifying via `inspect/1` breaks downstream log aggregation filtering on structured fields.

**Fix:** pass `reason: reason` directly. For `%Ecto.Changeset{}` branches, use `reason: changeset.errors`.

### SUGGESTION

**S-8: Kill-switch type is undocumented at the worker call site**

`lib/ad_butler/workers/audit_scheduler_worker.ex` line 35. If `config/runtime.exs` stored the raw string `"false"` instead of parsing to boolean, `if fatigue_enabled?` would always be truthy (silent misconfig). Current `runtime.exs:90` does parse with `== "true"`, so this is safe today — but a docstring note at the call site would harden against future config drift.

**S-9: `AuditHelpers` boundary and `@moduledoc false` are correct — no change needed.**

Two callers, same OTP app, both workers. Internal-only module with full `@doc`/`@spec` on exported functions. The `@moduledoc false` is justified.

---

## Idempotency-under-retry verdict

**Fully idempotent.** `bulk_insert_fatigue_scores/1` uses column-isolated `on_conflict: {:replace, [:fatigue_score, :fatigue_factors, :inserted_at]}` with `conflict_target: [:ad_id, :computed_at]` — safe to run repeatedly against the same 6-hour bucket without corrupting the `BudgetLeakAuditorWorker`'s parallel columns.

The `Enum.reduce_while` halts before any DB write (`bulk_insert` is called only after the full `entries` list is built), so a mid-account failure leaves the bucket clean and retry starts from scratch.

The `_ok_or_skipped` match in `audit_one_ad/4` correctly emits a score entry for both `:ok` and `:skipped` finding states — dedup does not suppress score writes.

The 6-hour bucket math (`div(now.hour, 6) * 6` on `DateTime.utc_now()`) is UTC-only and DST-safe.

---

## Confirmed still-resolved

- **B-1**: Formula `clicks = 80 - (6 - d) * 10` verified produces negative slope; heuristic fires. Resolved.
- **W-2**: Single `AuditHelpers.dedup_constraint_error?/1` implementation; no local copies. Resolved.
- **W-3**: Unreachable nil branch replaced with strict empty-map guard. Resolved.
