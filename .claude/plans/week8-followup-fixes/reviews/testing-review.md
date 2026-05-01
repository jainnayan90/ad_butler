# Testing Reviewer Findings — week8-followup-fixes

Reviewer: elixir-phoenix:testing-reviewer
Status: APPROVED — no iron law violations, no critical issues

## Verified clean

### `scrub_for_user/1` tests (`embeddings_test.exs:331-365`)
Struct literals (`%Embedding{}`) are exactly right — pure in-memory transform, no DB needed. Five cases cover meaningful partitions (per-kind scrubbing, passthrough, empty, mixed with order). No issues.

### Hash-assertion decoupling (`embeddings_refresh_worker_test.exs:77,100,130`)
Right call. `describe "ad_content/1"` block at line 200 owns the format contract independently. Raw string literals create intentional coupling: format change → `ad_content/1` tests fail loudly first, then perform tests fail with hash mismatch (clear two-signal failure). Comments at 74-76 and 97-98 make reasoning explicit.

### Drain assertion (`week8_e2e_smoke_test.exs:89-90`)
Strengthened `%{success: success, failure: 0}` + `assert success >= 1` correct. Previous `%{failure: 0}` would pass even with no jobs run.

### `async: false` on `embeddings_refresh_worker_test.exs:2`
Required by `set_mox_from_context` / global Mox mode. Smoke test moduledoc explains non-transactional DDL reason. Clean.

## Suggestions

### S1 — Add unknown-kind test for `scrub_for_user/1`

`embeddings_test.exs` after line 364

No test for an unknown/future kind (e.g., `%Embedding{kind: "future_kind"}`). Depending on whether function pattern-matches exhaustively or has catch-all, an unhandled kind would either raise `FunctionClauseError` or pass through. Either behaviour deserves a test as documentation. Suggestion only.

### S2 — `nearest/3` NOTE comment could be `@tag :flaky`

`embeddings_test.exs:107-111` — good hygiene, but `@tag :flaky` + CI exclusion would be cleaner if it ever starts flaking, rather than prose warning.

### S3 — Hardcoded `"Promo August 2026 — refreshed | "` at `embeddings_refresh_worker_test.exs:130`

If `creative_name` is ever made non-nullable (changing format), only `ad_content/1` block catches it — hardcoded string here silently drifts. Acceptable given comment discipline already present.

## Triage outcome

- S1: SKIP — function uses two clauses on `%Embedding{kind: "doc_chunk"}` and catch-all `%Embedding{}`, so behavior is well-defined; comment in moduledoc covers the contract. Cosmetic.
- S2: SKIP — premature; not flaking yet.
- S3: ACCEPTABLE TRADEOFF noted by reviewer.
