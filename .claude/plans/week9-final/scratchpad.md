# Scratchpad: week9-final-fixes

## Dead Ends (DO NOT RETRY)

(none yet)

## Decisions

### D-FN-01 — actions_log integer PK retained

User chose "Document deviation only" over the binary_id migration.
Rationale: append-only audit log; integer serial PK preserves insert
order without per-row UUID overhead. Schema/migration are internally
consistent (both declare integer PK). The W1 fix is documentation only.

### D-FN-02 — W2: implement bulk Analytics now, not "cap to 2 ads"

User chose the proper bulk implementation over the quick cap. This
makes Phase 4 the largest item in the plan. Mitigation: P4-T1 reads
the existing Analytics surface first, P4-T2 pins the signature in
this scratchpad before any code is written.

### D-FN-03 — `ad_account_id: nil` for SystemPrompt context

W9 ships only multi-account sessions. The SystemPrompt template uses
`(none)` as the fallback for `{{ad_account_id}}` (per
`system_prompt.ex:51`), so passing `nil` from the Server is safe today.
Per-session ad-account scoping is W11 work; flag if the template ever
embeds the value WITHOUT the `(none)` fallback.

### D-FN-04 — S2 skipped (TODO issue tracker reference)

The codebase has no issue-tracker convention referenced anywhere else.
Adding `# TODO(W11-issue-N)` would invent a convention not used
elsewhere. Also, W2 actually implements the bulk fn the TODO referenced,
so the TODO line is removed by P4-T5 and the question becomes moot.

### D-FN-05 — `truncate/2` returns nil on encode failure

Matches the existing `nil | String.t()` shape implied by callers
(`Helpers.maybe_payload_field/2` is already nil-tolerant). An empty
JSON object would be misleading because the truncated field is
displayed in the agent's reply payload — `nil` correctly signals
"no encodable value" without injecting noise.

### D-FN-06 — Pin `Analytics.get_ads_delivery_summary_bulk/2` shape after P4-T1

The signature in P4-T2 is provisional. After reading the existing
Analytics surface, decide:
- Does `get_insights_series/3` return `:summary` already, or does
  CompareCreatives compute it locally?
- If the latter: the bulk fn returns raw points and the caller folds
  `summary` itself.
- If the former: the bulk fn folds `summary` to keep the call site
  tight.
- **Pin the final shape in this scratchpad as D-FN-06b before writing
  P4-T3.**

### D-FN-06b — Final bulk shape (pinned)

CompareCreatives.summary_row/1 needs only the aggregated/averaged
values, not the time series. It's wasteful to ship 7-day point lists
through the tool payload and then fold them inside CompareCreatives.

Final shape:
```
@spec get_ads_delivery_summary_bulk(User.t(), [binary()], keyword()) ::
  %{binary() => %{
      spend_cents: integer(),
      impressions: integer(),
      avg_ctr: float() | nil,
      avg_cpm_cents: float() | nil,
      health: AdHealthScore.t() | nil
    }}
```

Two queries:
1. Insights aggregate over (ad_id ∈ user-scoped ad_ids, date_start ≥ today − 6d)
   with `GROUP BY ad_id` — yields spend_cents/impressions/avg_ctr/avg_cpm.
2. Latest `ad_health_scores` row per ad_id via `DISTINCT ON (ad_id)`.

Tenant scoping: pass through `Ads.scope(Ad, mc_ids)` to filter `ad_ids`
to user-owned only. Foreign ids are silently dropped (no key in result
map). Empty input or all-foreign → `%{}`.

Window default is `:last_7d` to match the CompareCreatives use case;
pass via opts so future callers can override.

## Open Questions

- Is `Analytics.unsafe_get_latest_health_score/1` callable from the
  bulk path, or does it need its own bulk variant? Resolve in P4-T1.
- Does the existing `e2e_test.exs` use `start_supervised!` or
  `Chat.send_message/3`? PubSub subscription needs to happen BEFORE
  the cast, so confirm the test invocation order in P5-T1.

## Handoff

All 5 phases shipped on 2026-05-02. Full suite: 547 tests / 0 failures
(baseline 530 + 1 W4 PubSub + 9 B3 SimulateBudgetChange + 5 W2 bulk
Analytics + 1 B1 SystemPrompt server test + 3 B2 GetAdHealth.truncate).
Credo --strict, check.tools_no_repo, check.unsafe_callers all green.

Bonus fix: while writing B3 tests, surfaced a latent ArithmeticError in
`Analytics.normalise_delivery_summary/1` — `SUM(bigint)` returns NUMERIC
in Postgres → Decimal in Elixir, and `Decimal / float` raises. Added
`decimal_to_integer/1` coercion helper. The function had zero coverage
before B3, so the bug had never been observed in tests.

W2 query envelope: 4 queries per call (mc_ids lookup, ownership filter,
delivery aggregate, health DISTINCT ON), invariant in N. Down from ~25
queries for a 5-ad invocation. Test in `analytics_test.exs` asserts both
the constant ≤ 4 and the invariance property.

W11 deferred items still tracked (per-session ad_account scoping wires
through `state` to `SystemPrompt.build/1`; pending_confirmations runtime;
write tools).
