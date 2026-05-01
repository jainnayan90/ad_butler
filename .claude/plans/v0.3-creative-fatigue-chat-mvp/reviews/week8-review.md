# Week 8 Review — Predictive Fatigue + Embeddings Plumbing

**Verdict: REQUIRES CHANGES** (2 BLOCKERS, 12 WARNINGS, 9 SUGGESTIONS after filtering)

5 review agents returned findings: security-analyzer, testing-reviewer, iron-law-judge, oban-specialist, ecto-schema-designer. The elixir-reviewer agent did not return parseable findings — see [elixir-review.md](.claude/plans/v0.3-creative-fatigue-chat-mvp/reviews/elixir-review.md) for the gap (numerics correctness in the Gauss-Jordan solver, not independently audited beyond test fixtures).

Raw counts: 6 BLOCKER, 18 WARNING, 12 SUGGESTION → after deconflict + persistent-pre-existing demotion: **2 / 12 / 9**.

---

## BLOCKERS (2)

### B1 — `EmbeddingsRefreshWorker.upsert_batch/3` swallows per-row errors and returns `:ok`
[lib/ad_butler/workers/embeddings_refresh_worker.ex:118-138](lib/ad_butler/workers/embeddings_refresh_worker.ex#L118-L138) (oban-specialist + iron-law-judge agree)

`Enum.each` calls `Embeddings.upsert/1` per candidate (also an N+1: 100 round-trips per tick). On `{:error, changeset}` it logs and discards the return; the calling clause returns `:ok` unconditionally. Failed upserts (pgvector dimension mismatch, DB constraint) are silently ignored — Oban marks the job complete, no retry, the row sits at its stale hash with no alerting signal.

**Fix (single change addresses both N+1 and silent-failure):**

Replace `Enum.each` + per-row `Embeddings.upsert/1` with a single `Repo.insert_all(Embedding, rows, on_conflict: ..., conflict_target: [:kind, :ref_id])`. Compare returned count vs `length(candidates)` and return `{:error, :partial_upsert_failure}` when they differ. Log `failure_count:` (allowlist key already present).

### B2 — No tenant-isolation test for `EmbeddingsRefreshWorker`
[test/ad_butler/workers/embeddings_refresh_worker_test.exs](test/ad_butler/workers/embeddings_refresh_worker_test.exs) (testing-reviewer)

CLAUDE.md says tenant isolation tests are non-negotiable. The worker is *intentionally* cross-tenant (it processes all ads/findings for a backfill cron), but that design choice is undocumented and untested. The next person to refactor this worker won't know whether cross-tenant processing is a bug or a feature.

**Fix:** Add a two-tenant test — insert ads under two `meta_connection` owners, run the worker, assert embeddings exist for both — encoding the deliberate cross-tenant invariant.

---

## WARNINGS (12)

### Architecture / Performance

**W1 — `heuristic_predicted_fatigue/1` is N+1 against `insights_daily`** [creative_fatigue_predictor_worker.ex:256-275](lib/ad_butler/workers/creative_fatigue_predictor_worker.ex#L256-L275) — `fit_ctr_regression/1` + `get_ad_honeymoon_baseline/1` (cache miss) per ad. At N=200 ads that's ~400 added round-trips, ~8s; at N=500 it can breach the 10-min `timeout/1`. **Fix:** pre-batch the 14-day `insights_daily` window with `ad_id IN ^ad_ids` and group by ad_id in Elixir, OR raise timeout to 20 min with a backlog item.

**W2 — `bulk_insert_fatigue_scores/1` can clobber existing `:metadata` with nil on retry** [analytics.ex:207](lib/ad_butler/analytics.ex#L207) — on_conflict replaces `:metadata` unconditionally. A retry that omits metadata wipes the cached honeymoon baseline, forcing recompute. **Fix:** document the invariant in the `@doc` AND verify the worker always sets metadata (or add COALESCE-style upsert).

### Operational

**W3 — `FatigueNightlyRefitWorker` unique window (1h) escapable by Lifeline 30-min rescue** [fatigue_nightly_refit_worker.ex:16](lib/ad_butler/workers/fatigue_nightly_refit_worker.ex#L16) — could cause double fan-out (no data corruption — predictor children dedup — but operational confusion). **Fix:** `period: 82_800` (23h), matching `DigestSchedulerWorker` / `AuditSchedulerWorker`.

**W4 — Default Oban backoff thrashes on rate limits** [embeddings_refresh_worker.ex:21](lib/ad_butler/workers/embeddings_refresh_worker.ex#L21) — 3 attempts consumed in ~75s; OpenAI rate limit window is ~60s, so all retries can land inside the rate-limit window. **Fix:** return `{:snooze, 90}` for `:rate_limit` so attempts aren't burned.

**W5 — 25-min unique vs 30-min cron leaves backfill overlap gap** [embeddings_refresh_worker.ex:24](lib/ad_butler/workers/embeddings_refresh_worker.ex#L24) — first deployment with large backfill could double embedding cost. **Fix:** widen unique to 28 min.

**W6 — Misleading `ad_id:` key in upsert-failure log** [embeddings_refresh_worker.ex:133](lib/ad_butler/workers/embeddings_refresh_worker.ex#L133) — when `kind` is `"finding"` or `"doc_chunk"` the value is not an ad UUID. **Fix:** rename to `ref_id:` and add `:ref_id` to the `config/config.exs` allowlist.

### Schema / Migrations

**W7 — CHECK constraint uses raw `execute` against project convention** [20260501000002_create_embeddings.exs:23-27](priv/repo/migrations/20260501000002_create_embeddings.exs#L23-L27) — every other CHECK in this codebase uses `create constraint(:table, :name, check: ...)`. **Fix:** swap to the DSL form. Functionally equivalent; convention conformance.

**W8 — Migration `down/0` drops `vector` extension unconditionally** [20260501000002_create_embeddings.exs:30-33](priv/repo/migrations/20260501000002_create_embeddings.exs#L30-L33) — safe today but breaks if a future migration adds another vector column. **Fix:** add a comment in `down/0` so the next vector-column author knows to update it.

**W9 — `validate_length(:content_hash, is: 64)` doesn't enforce hex** [embedding.ex:51](lib/ad_butler/embeddings/embedding.ex#L51) — passes any 64-char string. `hash_content/1` always produces hex but a bypass-the-helper path lets garbage through. **Fix:** `validate_format(:content_hash, ~r/\A[0-9a-f]{64}\z/)` (replaces the length check too).

### Security (forward-looking — release gates for W9 chat tooling)

**W10 — `Embeddings.nearest/3` accepts caller-controlled `kind` with no allowlist** [embeddings.ex:60-70](lib/ad_butler/embeddings.ex#L60-L70) — defense-in-depth. Add `when kind in @valid_kinds`.

**W11 — `Embeddings.nearest/3` has no `limit` ceiling — DoS surface** [embeddings.ex:60](lib/ad_butler/embeddings.ex#L60) — clamp via `min(limit, 50)` before W9 surfaces this to chat tools.

**W12 — `content_excerpt` stored unencrypted** [embedding.ex:29](lib/ad_butler/embeddings/embedding.ex#L29), [embeddings_refresh_worker.ex:126](lib/ad_butler/workers/embeddings_refresh_worker.ex#L126) — current sources are operator-controlled (ad names, finding text, help docs); no PII today. Add docstring contract: "never write PII; user-typed conversation content must use a separate Cloak'd kind."

---

## SUGGESTIONS (9)

**S1 — Test brittleness: idempotency test hardcodes content format** ([embeddings_refresh_worker_test.exs:71](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L71)) — silently degrades to first-run test if worker content format changes.

**S2 — `nearest/3` limit test doesn't verify WHICH rows return** ([embeddings_test.exs:167](test/ad_butler/embeddings_test.exs#L167)).

**S3 — `expect` count assumption: ads-before-findings ordering** ([embeddings_refresh_worker_test.exs:39-49](test/ad_butler/workers/embeddings_refresh_worker_test.exs#L39-L49)) — document or restructure with `stub`.

**S4 — `slope < 0.0` assertion has no lower bound** ([analytics_test.exs:673](test/ad_butler/analytics_test.exs#L673)) — `-1e-10` passes. Tighten to `< -0.001`.

**S5 — `week8_e2e_smoke_test.exs` missing `@moduletag :integration`** — runs on every `mix test`. Either add the tag or document the convention split with `test/integration/`.

**S6 — `analytics_test.exs` describes call DDL under `async: true`** — PERSISTENT from Week 7. Race risk on `create_insights_partition`. Extract these describes into a separate file with `async: false`.

**S7 — Logger `count` / `expected` semantics inverted** ([embeddings_refresh_worker.ex:103-108](lib/ad_butler/workers/embeddings_refresh_worker.ex#L103-L108)) — swap labels or rename `vectors_received`.

**S8 — Document model dim invariant in migration** ([20260501000002_create_embeddings.exs:13](priv/repo/migrations/20260501000002_create_embeddings.exs#L13)) — add `# 1536 = OpenAI text-embedding-3-small; dimension change requires a new migration`.

**S9 — Hardening**: filter_parameters should include API key names (`api_key`, `openai_api_key`, `anthropic_api_key`); `doc_ref_id/1` derivation deserves a one-line comment so future maintainers don't break the upsert key invariant; HNSW partial-per-kind index is a flag-for-future at >50k rows per kind.

---

## Verified Clean

- Migrations reversible; HNSW concurrency flags correct.
- Both new workers use `Oban.Worker` with `unique:` (no GenServer timer loops).
- Embeddings service uses Behaviour + `Application.get_env` indirection.
- No `String.to_atom` on user input; no DaisyUI; no `:float` for money.
- All Logger keys used in new files are in the `config/config.exs` allowlist; no `inspect/1` wrapping.
- All new modules have `@moduledoc`; all new public functions have `@doc` + `@spec`.
- Repo called only from context modules.
- ReqLLM API keys sourced via `System.fetch_env!` in `runtime.exs:60-64`; documented in `.env.example:62-67`.
- SQL injection: `nearest/3` pins `kind`, vector, limit with `^`; positional fragment placeholders.
- All 438 tests pass; `mix credo --strict` clean across 141 files.

---

## Persistent (carried from Week 7, not regressed)

- N+1 `Repo.update_all` in `ads.ex:550`
- Silent `with true <-` in `analytics.ex:348`
- `inspect(v)` on Logger metadata in `finding_detail_live.ex:233`
- `get_7d_frequency` test asserts exact float equality (W2 in testing-review)
- Heading naming + dead seed pass in `creative_fatigue_predictor_worker_test.exs`
