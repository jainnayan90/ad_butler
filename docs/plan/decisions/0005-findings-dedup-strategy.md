# ADR-0005: Findings Deduplication Strategy

**Status:** Accepted  
**Date:** 2026-04-29

## Context

`BudgetLeakAuditorWorker` runs every 6h per ad account. Without deduplication,
repeated audit runs for the same underlying issue would create a new finding row
on every execution, flooding the user's inbox and the `/findings` view.

## Decision

Deduplicate findings by `(ad_id, kind)`: skip insert if an unresolved finding
of the same kind already exists for that ad.

Implementation:
- Before creating a finding, call `Analytics.get_unresolved_finding(ad_id, kind)`.
- If a result is returned, skip the insert.
- A partial unique index on `(ad_id, kind)` where `resolved_at IS NULL` enforces
  this at the database level as a safety net.

## Resolution Policy

"Resolved" means `resolved_at IS NOT NULL`. A new finding is created only when:
1. No prior finding of the same `(ad_id, kind)` exists, or
2. The previous finding has been resolved (`resolved_at` is set).

Users resolve findings manually via the acknowledge flow or automated resolution
logic (not yet implemented in v0.2).

## Tradeoffs

- **Simpler than time-window dedup**: no sliding-window complexity, no edge cases
  around clock skew or job timing.
- **May delay re-alerting**: if a user resolves a finding but the root cause
  persists, no new finding appears until the next resolution-and-recurrence cycle.
  For v0.2 with manual review expected, this is acceptable — design partners are
  expected to actively monitor and triage.
- **Acknowledged ≠ resolved**: `acknowledged_at` is set by the user as a triage
  marker; it does not suppress new findings. Only `resolved_at` gates dedup.
