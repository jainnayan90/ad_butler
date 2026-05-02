# Security Re-Audit (Pass 2) — Week 9 Final

> **⚠️ EXTRACTED FROM AGENT MESSAGE** — Write denied to agent; orchestrator captured chat output verbatim.

**Verdict: PASS.** Both addressed SUGGESTIONs are correct. No new issues.
**0 BLOCKER / 0 WARNING / 1 SUGGESTION** (cosmetic, non-security).

## S3 — `SystemPrompt` nil coercion (clean)

`lib/ad_butler/chat/system_prompt.ex:53-54` — explicit `render_ad_account_id(nil), do: "(none)"` plus catchall `to_string(id)`.

- Caller at `lib/ad_butler/chat/server.ex:461-465` literally passes `ad_account_id: nil`. Today only `nil` (and, post-W11, a binary UUID) reaches the helper.
- `false` would render as `"false"` via `to_string/1` — obvious garbage to the LLM, not a foreign account id. Not a leak.
- Non-`String.Chars` struct (e.g. a raw `%AdAccount{}`) raises `Protocol.UndefinedError` — fail-loud, no silent coercion.
- W11 forward-compatibility: `to_string/1` is a no-op on UUID binaries; `nil → "(none)"` surfaces "no scope" as a documented sentinel rather than `""`. Contract matches behaviour.

## S4 — `filter_owned_ad_ids/2` pre-filter (clean)

`lib/ad_butler/ads.ex:165-186` — per-element `Ecto.UUID.cast/1`, then a single scoped query.

`Ecto.UUID.cast/1` returns `:error` for everything non-UUID (nil, atom, integer, malformed binary, struct, oversize blob), covering every case the removed `rescue Ecto.Query.CastError` handled. Survivors are guaranteed valid hyphenated UUID strings — `scope/2 + where: a.id in ^ids` produces a `uuid[]` parameter Postgres accepts without an adapter-side cast. Empty-input fast-path skips the DB entirely. No path reaches Postgres with malformed input.

Note: `fetch_ad_set/2` (`ads.ex:460-469`) and `fetch_ad/2` (`ads.ex:600-609`) keep their single-id `rescue` guards — consistent and intentional.

## `normalise_params/1` resource analysis (clean)

`lib/ad_butler/chat/server.ex:320-339` — atom keys pass through; binary keys go through `String.to_existing_atom/1` (Iron Law #3). Unknown keys aggregate to ONE `Logger.warning` per call. Atom table cannot grow. Log volume bounded by Anthropic's per-tool argument schema, not attacker cardinality. No DoS vector.

## W3 boundary tests (clean)

`test/ad_butler/chat/tools/simulate_budget_change_test.exs:139-173` — single-user fixtures, single-user `run_tool` calls, asserts only on `confidence`. Cross-tenant coverage lives at `:44-52`. No leak surface.

## Suggestion (non-security)

**SU-1.** `lib/ad_butler/chat/server.ex:335` — confirm `:unknown_keys` is in the Logger metadata allowlist in `config/config.exs`. CLAUDE.md says unallowlisted keys silently drop. Observability gap only, not security.

> **Orchestrator note**: verified — `:unknown_keys` IS in the allowlist at [config/config.exs:119](../../../config/config.exs#L119). SU-1 is a false flag; can be disregarded.

## Tools to run manually

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix precommit`
