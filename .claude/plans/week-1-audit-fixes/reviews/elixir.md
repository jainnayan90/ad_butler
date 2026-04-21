# Elixir Review: Week-1 Audit Fixes

⚠️ EXTRACTED FROM AGENT MESSAGE (Write permission denied in subagent context)

**Verdict**: PASS WITH WARNINGS — 0 blockers, 3 warnings, 1 suggestion

---

## Warnings

### W1: `meta_client/0` duplicated across two modules
`Accounts` and `TokenRefreshWorker` both define identical private helpers reading
`Application.get_env(:ad_butler, :meta_client, AdButler.Meta.Client)`.
If the key or default changes, both must be updated.
Fix: export from a shared boundary (e.g., `AdButler.Meta` module) or document the intentional duplication.

### W2: `list_expiring_meta_connections/2` — non-deterministic limit without `order_by`
`limit(^limit)` with no `order_by` means the 500 returned rows are arbitrary.
With >500 expiring connections, the most urgent tokens might be skipped.
Fix: add `|> order_by([mc], asc: mc.token_expires_at)` before `limit`.

### W3: `do_refresh/1` — three levels of nested `case`
The success path nests case-inside-case-inside-case. Correct but hard to follow.
Fix: flatten with a `with` chain (lower priority, correctness not affected).

---

## Suggestions

None beyond the warnings above.

---

## Focus-Area Answers

| Question | Finding |
|---|---|
| `meta_client()` per-invocation `Application.get_env` | Safe (runtime ETS read). Duplication is the concern, not performance. |
| `DateTime.add(:day)` vs old `:second` multiplication | Semantically identical. `:day` variant is cleaner. |
| `inspect(changeset.errors)` vs full changeset | Correct improvement — avoids leaking sensitive field values in logs. |
| Dep version tightening | All `~>` ranges are correct. No issues. |
