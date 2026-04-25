# Architecture Audit
Date: 2026-04-25

## Score: 87/100

## Issues Found

### 1. `Ads` calls `Accounts` directly on every user-scoped query — undocumented
`lib/ad_butler/ads.ex:13`

`AdButler.Ads` calls `Accounts.list_meta_connection_ids_for_user/1` inside every list/get
function. `MetadataPipeline` does the same but justifies it in `@moduledoc`. `Ads` has no
such explanation. Any signature change to that function silently touches every Ads query.
Recommendation: Document the coupling in `@moduledoc`, or accept `mc_ids` as a
first-class parameter and hoist the lookup to call sites.

### 2. `Ads.AdAccount` schema has `belongs_to` crossing into `Accounts` namespace
`lib/ad_butler/ads/ad_account.ex:24`

`belongs_to :meta_connection, AdButler.Accounts.MetaConnection` creates a compile-time
schema dependency from the `Ads` context into `Accounts`. The FK column is necessary;
the explicit `belongs_to` is optional and permanently entangles both contexts at the schema layer.

### 3. `AdButler.LLM` namespace has no context module
`lib/ad_butler/llm/`

There is a `Usage` schema and `UsageHandler` telemetry handler but no top-level `AdButler.LLM`
context module. Project convention (followed by `Accounts` and `Ads`) requires a context
module owning the public API. When an LLM client is wired, all callers will bypass any context boundary.

### 4. `CampaignsLive.handle_params/3` queries DB on disconnected render
`lib/ad_butler_web/live/campaigns_live.ex:48`

`Ads.list_campaigns/2` called unconditionally in `handle_params/3`, which fires on both the
disconnected HTTP render and the connected WebSocket render.

### 5. `LLM.Usage` missing `required_fields/0` schema convention
`lib/ad_butler/llm/usage.ex`

`Ads` schemas expose `required_fields/0` for `bulk_strip_and_filter/2`. `LLM.Usage` defines
`@required` as a private attribute and omits the public function — non-uniform convention.

## Clean Areas
Module naming perfectly consistent. No compile-time circular dependencies. Oban workers
idempotent with string keys. Money consistently `_cents` integers. Third-party clients
wrapped behind behaviours. Router pipelines correct with CSRF, CSP, rate-limiting.

## Score Breakdown

| Criterion | Score | Max | Notes |
|-----------|-------|-----|-------|
| Context boundaries respected | 18 | 25 | Ads→Accounts undocumented; AdAccount belongs_to crossing; no LLM context |
| Module naming consistency | 15 | 15 | Perfect |
| Fan-out <5 contexts per module | 15 | 15 | No module exceeds 3 contexts |
| API surface <30 funcs/context | 15 | 15 | Accounts: ~12; Ads: ~18 |
| No compile-time circular deps | 14 | 15 | Ads.AdAccount → Accounts.MetaConnection compile-time dep |
| Folder structure follows conventions | 10 | 15 | Missing LLM context module; handle_params DB in disconnected render |
