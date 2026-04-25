# Review: health-audit-findings-apr23 — Pass 2 (post-triage)

**Date:** 2026-04-25
**Verdict: PASS WITH WARNINGS** — 0 Blockers · 4 Warnings · 4 Suggestions
**Prior 14 findings:** All confirmed resolved.

---

## All Prior Findings: RESOLVED ✓

C1, W1–W4, S1–S9 from pass 1 are correctly implemented. No regressions.

---

## New Warnings

### W-N1 — `token_refresh_sweep_worker.ex:37+41` — double list traversal contradicts the W1 fix intent

**Source:** elixir-reviewer

```elixir
# Current — two O(n) passes
if length(raw) > @default_limit do ...
connections = Enum.take(raw, @default_limit)

# Preferred — one pass
{connections, overflow} = Enum.split(raw, @default_limit)
if overflow != [] do ...
```

W1 was fixed to avoid an extra COUNT query, but the implementation does two scans instead of one. `Enum.split/2` is the idiomatic single-pass form.

### W-N2 — `token_refresh_sweep_worker.ex:61` — atom-key fallback `args[:meta_connection_id]` is dead code

**Sources:** elixir-reviewer + oban-specialist (converged finding)

`Oban.insert_all` returns `Oban.Job` structs whose `args` field is always string-keyed after Oban's JSON round-trip. `args[:meta_connection_id]` can never be truthy. More seriously: if `args["meta_connection_id"]` is somehow `nil` for any job, the `nil || nil` result silently corrupts `inserted_ids` — a false-safe MapSet that makes every connection appear as conflict-skipped. The dead fallback was added for defensive correctness but achieves the opposite.

```elixir
# Fix: drop the dead branch
MapSet.new(inserted_jobs, & &1.args["meta_connection_id"])
```

Oban's string-key guarantee is confirmed by `schedule_changeset/1` using `"meta_connection_id"` and by Oban's JSON serialization path.

### W-N3 — `token_refresh_sweep_worker.ex:75` — `:info` log on every run including no-op sweeps

**Source:** elixir-reviewer

When no connections are expiring, all counters are zero but the `:info` log still fires every 6 hours. In a quiet system this adds log noise with no signal. Guard with `if total > 0` or use `:debug`.

### W-N4 — `plug_attack_test.exs` — `unique_octet/0` comment is now misleading

**Source:** testing-reviewer

The ETS flush before each test is now the actual isolation mechanism; `unique_octet` is cosmetic. The comment says "belt-and-suspenders" (accurate) but `unique_octet/0` still has no inline note explaining it is NOT the isolation guarantee. A future maintainer removing the ETS flush could incorrectly assume `unique_octet` still provides safety.

**Fix:** add one-line comment on `unique_octet/0`: `# for readability only — isolation is guaranteed by the ETS flush in setup`

---

## Suggestions

### S-N1 — `auth_controller_test.exs:118` — deprecated `Repo.aggregate/3` with field arg

```elixir
# Current — deprecated since Ecto 3.10
Repo.aggregate(AdButler.Accounts.User, :count, :id)

# Fix
Repo.aggregate(AdButler.Accounts.User, :count)
```

### S-N2 — `token_refresh_sweep_worker_test.exs:82` — `ObanMock` return `[]` needs an explanatory comment

`expect(ObanMock, :insert_all, fn _changesets -> [] end)` — add a comment: `# [] simulates on_conflict: :nothing skipping all inserts (normal steady-state)`

### S-N3 — `token_refresh_sweep_worker.ex` — tighten the `skipped` comment

```elixir
# Current (slightly misleading):
# "skipped" includes both conflict-skipped (normal steady-state) and genuine DB errors.

# Fix:
# on_conflict: :nothing conflict-skips are not returned — they are normal, not failures.
# A real DB error raises before reaching this line and is handled by Oban's retry logic.
```

### S-N4 — `token_refresh_sweep_worker_test.exs` — add `capture_log` test for the skipped-warning path

The new test confirms `:ok` is returned but does not verify `Logger.warning` fires when `skipped > 0`. If someone changes the warning to an error tuple, the test won't catch it.

```elixir
test "logs warning when all inserts are conflict-skipped" do
  insert(:meta_connection, status: "active",
    token_expires_at: DateTime.add(DateTime.utc_now(), 5 * 86_400, :second))
  expect(ObanMock, :insert_all, fn _changesets -> [] end)
  log = capture_log(fn -> perform_job(TokenRefreshSweepWorker, %{}) end)
  assert log =~ "Sweep skipped or failed to enqueue some refreshes"
end
```

---

## Pre-existing (not in diff — not actioned)

- `TokenRefreshWorker` snooze comment about attempt consumption is OSS-engine-specific (would be wrong under Oban Pro Smart Engine). Not in scope for this branch.
