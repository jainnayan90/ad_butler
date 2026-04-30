# Iron Law Audit — Week 7 (Pass 4)

**Verdict:** COMPLIANT WITH WARNINGS — 2 WARNINGS, 0 BLOCKERS

> Note: written by parent after agent returned findings inline.

---

## Violations

| # | Law | File:Line | Severity | Description | Fix |
|---|-----|-----------|----------|-------------|-----|
| 1 | #5 Error handling | `lib/ad_butler/ads.ex:563` | WARNING | `append_quality_ranking_snapshots/2` returns `:ok` unconditionally after `bulk_write_quality_ranking_history`. `SQL.query!` raises on failure so the exception propagates — not a true silent swallow — but callers cannot distinguish "nothing to write" from "write succeeded." | Document the `:ok` convention or return the `SQL.query!` result. |
| 2 | #8 Structured logging | `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:237,355` | WARNING | `reason: inspect(reason)` and `reason: inspect(changeset.errors)` coerce terms to strings, defeating structured log aggregation. | Use `reason: reason` directly; reserve `inspect/1` for genuinely non-serializable terms. |

---

## Confirmed Compliant

- **Iron Law #15 (Performance):** N+1 replaced with single `unnest()` UPDATE; parameterized via `$1::uuid[]/$2::text[]::jsonb[]` — no SQL injection surface.
- **Iron Law #5 (Error handling):** `bulk_write_quality_ranking_history` partial-failure safety — `SQL.query!` raises on DB error, propagates cleanly.
- **Iron Law #6 (Repo boundary):** Repo only in context modules, never in LiveViews or workers.
- **Iron Law #7 (Security/scope):** `paginate_findings`, `get_finding`, `acknowledge_finding` all enforce `scope_findings(user)`.
- **Iron Law #7 (Authorization):** `FindingDetailLive` handle_event `acknowledge` re-validates ownership via `Analytics.acknowledge_finding(current_user, id)`.
- **Iron Law #17 (LiveView streams):** `FindingsLive` uses `stream/3` with `reset: true`.
- **Iron Law #16 (Pagination):** `@per_page 50`, `total_pages`, `push_patch`, `<.pagination />`.
- **No DB queries in disconnected mount** — both LiveViews guard behind `if connected?(socket)`.
- **Iron Law #9 (Background jobs):** Oban `unique:` constraints on both workers keyed to `ad_account_id`. String keys in args (`%{"ad_account_id" => ...}`) throughout.
- **Iron Law #7:** No `String.to_atom/1` anywhere in `lib/`.
- **Decimal not float** — scores use `:decimal` for money/percentages.
- **Iron Law #14 (Migrations):** Reversible — `change` (auto-reversible) and explicit `up/down` with backfill where needed.
- **Iron Law #12 (Secrets/config):** `FATIGUE_ENABLED` via `System.get_env/2` with default — acceptable for optional feature flag.
- **Iron Law #1 (Documentation):** `@moduledoc`/`@doc` coverage on all changed modules and public functions.
- **Iron Law #18 (Styling):** No DaisyUI component classes introduced.
