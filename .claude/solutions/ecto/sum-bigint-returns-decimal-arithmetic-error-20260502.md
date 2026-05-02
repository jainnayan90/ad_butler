---
title: "SUM/AVG over bigint columns returns Decimal — coerce before arithmetic"
module: "Ecto.Query"
date: "2026-05-02"
problem_type: bug
component: ecto_query
symptoms:
  - "ArithmeticError: bad argument in arithmetic expression in code that divides a sum() result"
  - "Crash inside aggregate post-processing, e.g. trunc(impressions / safe_freq)"
  - "Function had no test coverage and the production code path was rarely exercised"
root_cause: "Postgres `SUM(bigint)` and `AVG(bigint)` return NUMERIC, which Postgrex/Ecto deserialize as `%Decimal{}` — not an integer. Direct arithmetic between Decimal and float (`Decimal / float`, `Float.round(Decimal)`) raises ArithmeticError. The same trap applies to any aggregate over a bigint or numeric column."
severity: medium
tags: [ecto, postgres, decimal, aggregate, sum, avg, bigint, schemaless]
related_solutions: []
---

## Problem

A schemaless aggregate query over a bigint column raises ArithmeticError when its result is used in float arithmetic:

```elixir
# Postgres column: impressions BIGINT NOT NULL DEFAULT 0
Repo.one(
  from i in "insights_daily",
    where: i.ad_id in ^bins,
    select: %{
      impressions: coalesce(sum(i.impressions), 0),
      avg_frequency: avg(i.frequency)
    }
)
|> normalise_delivery_summary()

# normalise_delivery_summary/1
defp normalise_delivery_summary(row) do
  impressions = row.impressions || 0
  freq = decimal_to_float(row.avg_frequency)
  safe_freq = if is_number(freq) and freq > 0, do: freq, else: 1.0

  reach_estimate = trunc(impressions / safe_freq)  # ← ArithmeticError here
  # ...
end
```

`row.impressions` is a `%Decimal{}`, not an integer — `Decimal / float` raises.

## Why it bites

Postgres aggregate return types:

| Input column | `SUM(...)` returns | `AVG(...)` returns |
|--------------|--------------------|--------------------|
| `smallint`   | `bigint`           | `numeric`          |
| `integer`    | `bigint`           | `numeric`          |
| `bigint`     | `numeric`          | `numeric`          |
| `numeric`    | `numeric`          | `numeric`          |
| `real/double`| matches input      | matches input      |

Postgrex maps `numeric` → `%Decimal{}`. Ecto only coerces aggregate results when you have a `select: %SomeSchema{...}` cast — schemaless `from "table"` queries do NOT cast and you get the raw Decimal.

The trap is invisible until the aggregate result hits `Float.round/2`, division by a float, or any `Kernel.+/2` mixed with a number — at which point it raises `ArithmeticError: bad argument in arithmetic expression`.

## Solution

Always coerce aggregate results explicitly before arithmetic:

```elixir
defp normalise_delivery_summary(row) do
  impressions = decimal_to_integer(row.impressions || 0)
  spend_cents = decimal_to_integer(row.spend_cents || 0)
  freq = decimal_to_float(row.avg_frequency)
  safe_freq = if is_number(freq) and freq > 0, do: freq, else: 1.0

  reach_estimate = trunc(impressions / safe_freq)
  # ...
end

defp decimal_to_integer(%Decimal{} = d), do: Decimal.to_integer(Decimal.round(d, 0, :down))
defp decimal_to_integer(n) when is_integer(n), do: n
defp decimal_to_integer(n) when is_float(n), do: trunc(n)
defp decimal_to_integer(_), do: 0
```

`Decimal.round/3` with `:down` truncates without raising on non-integer inputs.

## Alternative: cast in the SELECT

```elixir
select: %{
  impressions: type(coalesce(sum(i.impressions), 0), :integer)
}
```

This works but only if you trust the value to fit in an Elixir integer (Postgres BIGINT does). Coercing in Elixir is more flexible because it survives column-type changes.

## Detection

Code paths that:
1. Use `from "schemaless_table"` (no schema cast),
2. Aggregate via `sum/avg` over a bigint or numeric column,
3. Then do `result / something`, `Float.round(result, n)`, or pass result to `:math` / `:erlang` numeric BIFs.

`grep` for `coalesce(sum(` or `avg(` in `from "..."` queries — those are the candidates.

## Test pattern

The bug is silent if the function is never called with real aggregated data. Make sure aggregate paths have a test that:
- Inserts at least one row,
- Calls the public function,
- Asserts the structural shape of the returned map (forces evaluation through every coercion).

The function that bit us had zero coverage; once the test ran with real impressions data, the ArithmeticError was immediate.
