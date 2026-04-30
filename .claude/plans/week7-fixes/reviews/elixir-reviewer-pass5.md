# Elixir Review — Pass 5 (verifying pass-4 fixes)

**Verdict:** PASS WITH WARNINGS
**New issues found:** 1 WARNING, 1 SUGGESTION, 1 MISSING TEST

> Note: written by parent after agent returned findings inline.

---

## Pass-4 fix verification

- **W-4** PASS. All three `inspect/1` calls removed from Logger metadata in `creative_fatigue_predictor_worker.ex`.
- **W-5** PASS. `@doc` for `append_quality_ranking_snapshots/2` explicitly states the raise-on-failure contract.
- **W-6** PASS. `compute_ctr_slope/2` uses three-head pattern `[]` / `[_]` / `rows`. `length/1` is gone.
- **W-7** PASS. `avg_cpm/1` returns `{:error, :insufficient}`; `get_cpm_change_pct/1` caller's `with ... else _ -> nil` chain handles correctly.
- **W-8** PASS. `finding_detail_live.ex:73–80` adds `<div :if={!@finding}>` block. `mount/3` seeds `@finding` as `nil`.
- **S-8** PASS. `simple_linear_slope/1` uses `Enum.zip_reduce/4`.
- **S-9** PASS. `load_findings/1` no longer calls `Ads.list_ad_accounts/1`. `mount/3` seeds empty `:ad_accounts_list`.
- **S-10** PASS. `Finding` `@moduledoc` names both workers + dedup pattern.
- **S-11** PASS. Inline comment guards against compile-time freeze.

---

## NEW Issues

### WARNING

**`lib/ad_butler/workers/audit_scheduler_worker.ex:63`** — `inspect(reason)` survives in the `Oban.insert/1` error branch. This file was touched for S-11 but line 63 was out of scope for W-4 (which targeted only the fatigue predictor). Violates the same aggregation rule now codified in CLAUDE.md "Logging and Observability" and `.claude/solutions/logging/structured-logger-inspect-defeats-aggregation-20260430.md`.

```elixir
# current
Logger.error("audit_scheduler: unexpected insert error", reason: inspect(reason))

# fix
Logger.error("audit_scheduler: unexpected insert error", reason: reason)
```

### SUGGESTION

**`lib/ad_butler_web/live/finding_detail_live.ex:75–84`** — The `← Back to Findings` link is duplicated verbatim between the placeholder `<div :if={!@finding}>` block and the main `<div :if={@finding}>` block. Not a correctness issue but drift risk if the route changes. Consider a private function component or shared `<.link>` snippet.

---

## Missing tests

**`test/ad_butler_web/live/finding_detail_live_test.exs`** — No test covers the W-8 disconnected-render path. This was explicitly flagged as required in the pass-4 triage and is now codified in CLAUDE.md. `live/2` triggers a connected mount; the placeholder only appears on the static render. Suggested test:

```elixir
test "disconnected render shows loading placeholder and back link", %{conn: conn, user: user, finding: finding} do
  conn = log_in_user(conn, user)
  html = get(conn, ~p"/findings/#{finding.id}") |> html_response(200)
  assert html =~ "Loading finding"
  assert html =~ ~s(href="/findings")
end
```
