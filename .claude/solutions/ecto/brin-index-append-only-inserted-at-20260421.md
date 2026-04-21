---
title: "Use BRIN index instead of B-tree for monotonically increasing inserted_at on append-only tables"
module: "Ecto.Migration"
date: "2026-04-21"
problem_type: performance
component: ecto_migration
symptoms:
  - "Large B-tree index on inserted_at column consumes excessive disk space"
  - "insert_at range scans on append-only ledger tables are slower than expected"
  - "Index bloat on high-write tables (LLM usage logs, audit ledgers, event streams)"
root_cause: "B-tree indexes are built for random-access patterns. Append-only tables with monotonically increasing timestamp columns (inserted_at via fragment('now()')) insert rows in time order — BRIN is designed exactly for this access pattern and is orders of magnitude smaller."
severity: low
tags: [migration, index, brin, performance, append-only, ledger, inserted_at]
related_solutions: []
---

## Problem

Using a standard B-tree index on `inserted_at` for an append-only table (like an LLM usage ledger or audit log) is wasteful:

```elixir
# Standard — works but oversized for append-only data
create index(:llm_usage, [:inserted_at])
```

B-tree indexes store one entry per row and maintain balanced structure for arbitrary insert order. On append-only tables where `inserted_at` always increases monotonically, this overhead is unnecessary.

## Solution

Use a BRIN (Block Range INdex) index for monotonically increasing columns on append-only tables:

```elixir
# BRIN — far smaller, same range-scan performance for monotonic data
create index(:llm_usage, [:inserted_at], using: :brin)
```

BRIN stores only the min/max value per block range rather than per row. For a 100M-row table:
- B-tree: ~2–4 GB index
- BRIN: ~128 KB index (10,000× smaller)

Range scan performance is comparable or better for time-range queries (e.g., "cost this month").

## When to Use BRIN vs B-tree

| Use BRIN | Use B-tree |
|----------|------------|
| Append-only table (no updates/deletes to indexed col) | Random inserts |
| Monotonically increasing values (timestamps, sequences) | Equality lookups |
| Range scans only (date ranges) | Point lookups by value |
| High-write, high-volume tables | Composite index (user_id + inserted_at) |

## Important Caveats

- **BRIN does NOT help composite indexes**: Keep `[:user_id, :inserted_at]` as B-tree — it handles point lookups by user_id efficiently.
- **BRIN only works well if rows are physically stored in insert order**: Append-only tables satisfy this; tables with frequent updates/deletes do not.
- **BRIN is not suitable if rows are deleted and re-inserted** out of order.

## Applied Pattern

```elixir
# llm_usage: append-only ledger
create index(:llm_usage, [:user_id, :inserted_at])          # B-tree: point + range per user
create index(:llm_usage, [:inserted_at], using: :brin)      # BRIN: global time range scans
create index(:llm_usage, [:conversation_id])                 # B-tree: point lookup
```
