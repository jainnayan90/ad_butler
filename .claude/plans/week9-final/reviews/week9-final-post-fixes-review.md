# Review: W9 Final Triage Fixes — Post-Implementation

**Date**: 2026-05-02
**Verdict**: **PASS WITH WARNINGS**
**Scope**: Implementation of the 10 triage-approved fixes from `week9-final-triage.md`, executed across 5 phases by `/phx:full`.

> All 4 review agents had Write denied to `reviews/*.md`. Findings were extracted from agent return messages and captured verbatim by the orchestrator into the per-agent files.

---

## Verification Gate (already green from /phx:full)

| Check | Result |
|---|---|
| `mix compile --warnings-as-errors` | ✅ |
| `mix format --check-formatted` | ✅ |
| `mix credo --strict` | ✅ 1134 mods/funs, no issues |
| `mix check.tools_no_repo` | ✅ |
| `mix check.unsafe_callers` | ✅ |
| `mix test` | ✅ 547 / 0 failures (target ≥ 535) |

All 10 acceptance criteria from `plan.md` checked off.

---

## Findings

### BLOCKERs (0)
None.

### WARNINGs (4)

| # | Severity | Source | Finding |
|---|---|---|---|
| W1 | WARNING | elixir | `analytics.ex:365` — `{:ok, uuid} = Ecto.UUID.load(bin)` is a bare match. Theoretical `MatchError` if a 16-byte binary fails to load. Practically unreachable (Postgres always returns valid 16-byte UUIDs through the bytea path), but defensive `case`/`with` reads better. |
| W2 | WARNING | elixir | `ads.ex:171-173` — `rescue Ecto.Query.CastError` in `filter_owned_ad_ids/2` is too broad; could swallow connection errors. Inputs are internal UUIDs (already validated upstream), so the rescue path is dead today. Either drop it or pre-filter with `Ecto.UUID.dump/1`. Security agent's S2 says the same. |
| W3 | WARNING | testing | `simulate_budget_change_test.exs:91-137` — confidence band exact boundaries (7-day → `:medium`, 21-day → `:high`) not tested. Off-by-one flip from `>=` to `>` would pass undetected. |
| W4 | WARNING | testing | `analytics_test.exs:426-472` — query-count drain uses `after 0` polling between two telemetry runs without flushing the mailbox. Sandbox infrastructure event between runs could perturb the invariance assertion. |

### SUGGESTIONs (4)

| # | Source | Finding |
|---|---|---|
| S1 | elixir | `server.ex:320-333` — `normalise_params/1` rescue drops ALL valid params if any one key fails `String.to_existing_atom`. Switch to per-key `Enum.reduce` so only the unknown key is dropped. |
| S2 | elixir | `compare_creatives.ex:79` — `Map.get(score, key)` on `AdHealthScore.t()` could be two pattern-matched function heads for compile-time safety. |
| S3 | security | `system_prompt.ex:48-52` — `Chat.Server` passes `ad_account_id: nil`, so `to_string(nil)` yields `""` rather than the documented `"(none)"`. Cosmetic until `system.md` references `{{ad_account_id}}` (W11). |
| S4 | security | `ads.ex:160-173` — defense-in-depth: pre-filter inputs with `Ecto.UUID.dump/1` before query (mirrors `Analytics.dump_uuids/1`). Current rescue is safe. |

### NITs (1)

- `analytics.ex:305-313` — redundant `case owned do [] -> %{}` after the `def …([], _opts), do: %{}` head clause. Reads cleaner as `if owned == []`.

### PRE-EXISTING (out of scope)

- `ads.ex:890` — Iron-law judge flagged `Logger.error` with `#{Exception.message(e)}` interpolation duplicated into `:reason` metadata. Verified via `git diff` — this line is OUTSIDE the W9 final diff. Track separately.

---

## What got verified (clean)

- **B1 SystemPrompt wiring** — system message reaches LLM as first element; trust-boundary phrase asserted in test; recursive `react_step/7` re-includes system message every turn.
- **B2 GetAdHealth.truncate safety** — Jason.encode failure path returns `nil` without logging the raw map (no PII leak via observability).
- **B3 SimulateBudgetChange tests** — 9 tests (tenant isolation, happy path, three confidence bands, zero-budget no-raise, schema validation). Iron Laws clean.
- **W2 Bulk Analytics tenant scoping** — every caller-supplied `ad_ids` funnels through `Ads.filter_owned_ad_ids/2` BEFORE bulk queries; foreign IDs absent from result map (no sentinel leak).
- **W3 normalise_params logging** — only binary KEYS logged, never values; `:unknown_keys` in allowlist; `String.to_existing_atom/1` (no atom exhaustion).
- **W4 PubSub assertions** — subscription happens before cast (race-free).
- **S3 e2e tool-message threading** — assertions correctly placed on 2nd and 3rd `expect` callbacks.
- **Context boundary** — `Analytics` does NOT alias `Ads.{Ad, AdAccount}` schemas; ownership delegated through `Ads.filter_owned_ad_ids/2`.
- **Compound** — bonus latent fix (`SUM(bigint) → Decimal / float ArithmeticError`) captured at `.claude/solutions/ecto/sum-bigint-returns-decimal-arithmetic-error-20260502.md`.

---

## Recommendation

**PASS WITH WARNINGS.** All 4 WARNINGs are defensive/non-functional — none of them break anything that's shipping today. The 4 SUGGESTIONs are quality-of-life improvements. None gate W11.

Suggested follow-up: bundle W1+W2+W4 (small, mechanical fixes) + S1 (real robustness improvement) as a single quick fix-up commit before W11 starts. W3 is a test-quality improvement that pairs naturally with that.
