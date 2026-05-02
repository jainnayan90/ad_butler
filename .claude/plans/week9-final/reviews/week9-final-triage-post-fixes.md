# Triage: W9 Final Post-Fix Review

**Date**: 2026-05-02
**Source**: [week9-final-post-fixes-review.md](week9-final-post-fixes-review.md)
**Decision**: Fix ALL approved items in this session (no separate fix-up plan).

---

## Fix Queue (9 items)

### WARNINGs (4)

- [x] **W1 — Replace bare match on `Ecto.UUID.load/1`**
  File: [analytics.ex:365](../../../lib/ad_butler/analytics.ex#L365)
  Change: `{:ok, uuid} = Ecto.UUID.load(bin)` → `case` expression with explicit `:error` clause.

- [x] **W2 — Tighten `filter_owned_ad_ids/2` rescue**
  File: [ads.ex:171-173](../../../lib/ad_butler/ads.ex#L171)
  Change: drop `rescue Ecto.Query.CastError`. Pre-filter inputs with `Ecto.UUID.dump/1` so cast errors never reach the query.

- [x] **W3 — Test exact confidence-band boundaries**
  File: [simulate_budget_change_test.exs:91-137](../../../test/ad_butler/chat/tools/simulate_budget_change_test.exs#L91)
  Change: add tests seeding exactly 7 days (assert `:medium`) and exactly 21 days (assert `:high`).

- [x] **W4 — Flush mailbox between query-count runs**
  File: [analytics_test.exs:426-472](../../../test/ad_butler/analytics_test.exs#L426)
  Change: drain stale telemetry messages between the 5-ad and 1-ad measurement blocks; or assert `one_ad_count <= 4` independently rather than equality.

### SUGGESTIONs (4)

- [x] **S1 — Per-key `Enum.reduce` in `normalise_params/1`**
  File: [server.ex:320-333](../../../lib/ad_butler/chat/server.ex#L320)
  Change: rescue `ArgumentError` per-key so only unknown keys drop; valid params survive.

- [x] **S2 — Pattern-match function heads in `health_metric/2`**
  File: [compare_creatives.ex:79](../../../lib/ad_butler/chat/tools/compare_creatives.ex#L79)
  Change: two heads on `%AdHealthScore{fatigue_score: v}` and `%AdHealthScore{leak_score: v}`.

- [x] **S3 — Coerce `nil` → `"(none)"` in `SystemPrompt.build/1`**
  File: [system_prompt.ex:48-52](../../../lib/ad_butler/chat/system_prompt.ex#L48)
  Change: explicit nil branch so `Chat.Server`'s `ad_account_id: nil` renders as the documented sentinel rather than `""`. Cosmetic until W11; pairs with B1 wiring.

- [x] **S4 — Defense-in-depth UUID pre-filter in `filter_owned_ad_ids/2`**
  File: [ads.ex:160-173](../../../lib/ad_butler/ads.ex#L160)
  Change: bundled with W2 — `Ecto.UUID.dump/1` filter eliminates the rescue-as-fallback.

### NIT (1)

- [x] **N1 — Replace `case owned do [] -> %{}` with `if owned == []`**
  File: [analytics.ex:305-313](../../../lib/ad_butler/analytics.ex#L305)
  Change: trivial readability.

---

## Skipped

(none — user approved everything)

## Deferred / Out of scope

- **PRE-EXISTING** [ads.ex:890](../../../lib/ad_butler/ads.ex#L890) — `Logger.error` interpolation in `bulk_upsert_insights`. Outside W9 final diff. Track separately or fold into next pass.

---

## Execution

User chose: **Fix in this session**. Proceeding directly with edits, then re-running the verification gate (`mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict && mix check.tools_no_repo && mix check.unsafe_callers && mix test`).
