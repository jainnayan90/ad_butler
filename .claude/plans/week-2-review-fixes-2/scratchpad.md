# Scratchpad: week-2-review-fixes-2

## Key Decisions

- **W4 float fix**: Integer multiplication for comparisons (`cpa_3d * 10 > baseline_cpa * 25`), not Decimal. Equivalent logic, no new abstractions. Float ratio kept in evidence map as display-only.
- **B1 spec**: `acknowledge_finding/2` now returns `{:error, :not_found}` via `with` passthrough — must update `@spec` to include third variant.
- **P3-T2 UUID cast**: `Ecto.UUID.cast/1` — empty string maps to `:error` → nil, dropped by `maybe_put`. No new dep.
- **W6 fix**: `normalised when not is_nil(normalised.date_start)` pattern guard in `with` arm — idiomatic, eliminates the inverted boolean anti-pattern.

## No Dead-Ends Yet

## API Failure — 2026-04-29 10:22

Turn ended due to API error. Check progress.md for last completed task.
Resume with: /phx:work --continue
