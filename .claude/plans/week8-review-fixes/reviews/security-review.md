# Security Review — week8-review-fixes

**Verdict:** PASS — ship. 0 BLOCKERS, 1 WARNING (release-gate for W9), 2 SUGGESTIONS.

> ⚠️ Captured from security-analyzer agent chat output (Write was denied).

## Resolved since last audit

- **W8/SEC-WARN-1** (cross-tenant kNN leak) — `tenant_filter_results/2` at `lib/ad_butler/embeddings.ex:175-193` with fail-closed raise on unknown kinds; tests at `test/ad_butler/embeddings_test.exs:242-321`.
- **W8/SEC-WARN-2** (PII rules) — documented in `lib/ad_butler/embeddings/embedding.ex:19-32`.
- **W8/SEC-SUG-3** (`:filter_parameters`) — verified `config/config.exs:146-162`.

## Verifications

- **V1 fail-closed on unknown kinds**: PASS — `embeddings.ex:179-185` splits three ways, residual unknowns raise. Test at `embeddings_test.exs:308-317`.
- **V2 `doc_chunk` pass-through**: PASS — only writer is `lib/mix/tasks/ad_butler.seed_help_docs.ex:76` (admin task). No user-facing writers.
- **V3 bypass of `tenant_filter_results/2`**: PASS today — `Embeddings.nearest` has only test callers. No production user-facing path exists yet.
- **V4 OpenAI key handling**: PASS — `embeddings/service.ex:28-30` reads only model spec from app config; ReqLLM resolves the key from `runtime.exs:60-64` (`System.fetch_env!("OPENAI_API_KEY")`).
- **V5 Logger metadata allowlist**: PASS — `kind`, `count`, `vectors_received`, `reason`, `ref_id`, `failure_count` all present in `config/config.exs:88-141`.
- **V6 `unsafe_*` boundary**: PASS — only web caller is `lib/ad_butler_web/live/finding_detail_live.ex:34` (`Analytics.unsafe_get_latest_health_score`), correctly gated by `Analytics.get_finding(current_user, id)` on line 32. New `unsafe_list_ads_with_creative_names/0` and `unsafe_list_all_findings_for_embedding/0` are referenced only by `EmbeddingsRefreshWorker`.
- **V7 PII in new logs**: PASS — `embeddings_refresh_worker.ex:126,138,148,155,194` log only kind/count/reason metadata; no ad/finding text or tokens.

## NEW WARNING (release-gate, W9)

**WARN-1** — `lib/ad_butler/embeddings/embedding.ex:19-32` documents the `content_excerpt` rendering rule but nothing in code prevents a future tool from selecting and rendering the field. `tenant_filter_results/2` keeps the field populated on retained rows.

→ For the first W9 chat-tool PR: drop `content_excerpt` from the projection used by user-facing surfaces, OR add `Embeddings.scrub_for_user/1` that nils the field when `kind != "doc_chunk"`. Document in W9 plan.

## Suggestions

- **SUG-1** (carryover) — `lib/mix/tasks/ad_butler.seed_help_docs.ex:48-63`: wrap `Path.wildcard` results with `Path.safe_relative/2` against `Application.app_dir(:ad_butler, "priv/embeddings/help")` to defend against future symlinks. Low priority.
- **SUG-2** — `lib/ad_butler/embeddings.ex:179`: add `# safe: doc_chunk is admin-curated only — see seed_help_docs.ex` near the doc_chunk split so a future user-writable source forces a re-audit.

## Iron Law pass

Atom exhaustion, `raw/1`, `:erlang.binary_to_term`, SQL injection (all `nearest/3`/`list_ref_id_hashes/1` fragments parameterized with `^`), Repo boundary (Repo calls stay in contexts), tenant scope (via `Ads.list_ad_ids_for_user/1` + `Analytics.list_finding_ids_for_user/1` — both MetaConnection-scoped), secrets-in-code (none — `runtime.exs` `fetch_env!`), Cloak (no PII written): **all clean**.

## Manual tools to run

`mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`, `mix credo --strict`.
