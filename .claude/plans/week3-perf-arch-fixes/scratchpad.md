# Scratchpad — week3-perf-arch-fixes

## Key Decisions

### Publisher pool approach
Chose `Registry` + `DynamicSupervisor` over `poolboy`/`nimble_pool` — no extra dep,
fits OTP patterns already in the codebase. Pool size configurable via app env.

### bulk_validate removal
`@required` module attributes are compile-time — not accessible at runtime via
`schema_mod.@required`. Need to either:
- Add `def required_fields, do: @required` to each schema (preferred — one line each)
- Or pattern-match required fields from the changeset's `data.required` after casting
The first approach is simpler and keeps schemas self-describing.

### Cursor-based batching strategy
Keyset pagination on `id` (binary_id = UUID v4). UUID v4 is random, not time-ordered,
so keyset pagination is less efficient than on a sequence — but still far better than
offset. Alternative: add an auto-increment `row_number` column, or use `inserted_at`
as the cursor (ordered). For now, stream via `Repo.stream` inside a transaction is the
simplest approach and avoids keyset complexity entirely.

### Phase ordering constraint
Task 1.3 (batch MetaConnections) MUST land before 2.1 (remove Accounts alias).
Task 1.1 (Publisher pool) MUST land before 3.4 (await_connected fix — it changes the
GenServer interface that await_connected depends on).

## Dead Ends
(none yet)
