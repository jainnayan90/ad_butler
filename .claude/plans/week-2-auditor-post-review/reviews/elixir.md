# Elixir Review: week-2-auditor-post-review

⚠️ EXTRACTED FROM AGENT MESSAGE (agent denied Write access)

## Summary
**Verdict**: REQUIRES CHANGES — 3 critical, 2 warnings, 3 suggestions

---

## Critical

### C1 — `with true <-` misuse in `check_cpa_explosion`
`budget_leak_auditor_worker.ex:174`

`with` is for chaining tagged-tuple operations. `true <- condition` turns it into a disguised `cond` and makes `else _ -> :skip` opaque. Refactor to explicit `if` guards or pattern-matched function heads.

### C2 — `Ecto.UUID.dump!/1` unnecessary and raises on bad input
`ads.ex` (unsafe_list_30d_baselines)

```elixir
# Current — bypasses Ecto type system, raises on malformed UUID
where: v.ad_id in ^Enum.map(ad_ids, &Ecto.UUID.dump!/1),

# Better — let Ecto cast
where: type(v.ad_id, :binary_id) in ^ad_ids,
```

`ad_ids` are already `:binary_id` strings from prior query results; Ecto handles the cast automatically.

### C3 — Plain `=` assignments mixed into `with` arms in `check_placement_drag`
`budget_leak_auditor_worker.ex:242`

`cpas = Enum.map(...)`, `max_cpa = Enum.max(cpas)`, `min_cpa = Enum.min(cpas)` are plain assignments, not pattern matches — they belong in the `do` body. Also `when length(placements) >= 2` is O(n); use `[_, _ | _] = placements` instead.

---

## Warnings

### W1 — `_ = Ads` suppresses unused alias in `FindingDetailLive`
`finding_detail_live.ex` — Remove the alias if Ads is not used; dead-assignment suppression is a code smell.

### W2 — Nested `if` in `check_stalled_learning` both returning `:skip`
`budget_leak_auditor_worker.ex:292` — Collapse outer + inner `if` into one compound condition.

### W3 — `handle_info(:reload_on_reconnect)` duplicates `handle_params` logic
`findings_live.ex:111` — Both callbacks build identical opts and call `paginate_findings` + `list_ad_accounts`. Extract to a private `load_findings(socket)` helper.

---

## Suggestions

- S1: `unless failed == []` → `unless Enum.empty?(failed)` in AuditSchedulerWorker
- S2: `apply_check/4` design is clean — no change needed
- S3: `unsafe_build_ad_set_map` pipe starts with `Repo.all(...)` — idiomatic to start with schema module
