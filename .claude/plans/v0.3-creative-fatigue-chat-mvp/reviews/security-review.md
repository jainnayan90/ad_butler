# Week 8 Security Review — Embeddings + ReqLLM + Workers

⚠️ EXTRACTED FROM AGENT MESSAGE (Write was denied for the agent; findings preserved verbatim from chat output)

**Verdict: PASS WITH WARNINGS** — 0 BLOCKERS, 3 WARNINGS, 4 SUGGESTIONS.

Files reviewed: `lib/ad_butler/embeddings.ex`, `lib/ad_butler/embeddings/embedding.ex`, `lib/ad_butler/embeddings/service.ex`, `lib/ad_butler/embeddings/service_behaviour.ex`, `lib/ad_butler/workers/embeddings_refresh_worker.ex`, `lib/mix/tasks/ad_butler.seed_help_docs.ex`, `priv/repo/migrations/20260501000002_create_embeddings.exs`, `priv/repo/migrations/20260501000003_add_embeddings_hnsw_index.exs`, `config/runtime.exs`, `config/config.exs`, `.env.example`.

---

## WARNINGS (3)

### W1 — `Embeddings.nearest/3` accepts caller-controlled `kind` with no allowlist guard
`lib/ad_butler/embeddings.ex:60-70`

`nearest/3` and `list_ref_id_hashes/1` guard only with `is_binary(kind)`. SQL injection is impossible (pinned with `^kind`), but a future chat tool that forwards a user/LLM-supplied `kind` would let callers probe arbitrary kinds and CPU-amplify HNSW search. Today the only callers are the worker + tests with literal strings, so this is forward-looking.

Defense-in-depth fix:

```elixir
@valid_kinds ~w(ad finding doc_chunk)
def nearest(kind, query_vector, limit)
    when kind in @valid_kinds and is_integer(limit) and limit > 0 do ...
```

Mirrors `Embedding.@kinds` and the DB CHECK constraint. **Iron Law: VALIDATE AT BOUNDARIES.**

### W2 — `nearest/3` has no `limit` ceiling — DoS surface for chat consumers
`lib/ad_butler/embeddings.ex:60`

`limit` is any positive integer. HNSW search on 1536-dim vectors is CPU-intensive; an LLM-supplied "give me top 10000" becomes a budget-shaped DoS. Add `min(limit, @max_limit)` clamp (e.g. 50). **Release-gate prerequisite for W9 chat tool integration**, not a blocker today.

### W3 — `content_excerpt` stored unencrypted; bypasses Cloak for any future PII-bearing source
`lib/ad_butler/workers/embeddings_refresh_worker.ex:126`, `lib/mix/tasks/ad_butler.seed_help_docs.ex:80`, `lib/ad_butler/embeddings/embedding.ex:29`

Plaintext `:string` column holding 200 chars of source. Today's sources are operator-controlled (ad names, finding text, help docs). The embedding row creates a *second* unencrypted copy that survives source deletion (no FK). Extends blast radius of any future "names contained PII" incident, and contradicts CLAUDE.md "Use Cloak to encrypt PII at rest" if W9 introduces a `kind=conversation` carrying user-typed prompts. Add docstring contract: "never write PII; user-typed conversation content must go through a separate Cloak'd `kind`."

---

## SUGGESTIONS (4)

### S1 — Document dual-enforcement of `kind` allowlist
`lib/ad_butler/embeddings.ex:39-50`

`upsert/1` is safe — changeset has `validate_inclusion(:kind, @kinds)` and DB has `embeddings_kind_check`. Add moduledoc note discouraging future callers from skipping the changeset.

### S2 — `Logger.error(... reason: reason)` with raw ReqLLM error struct
`lib/ad_butler/workers/embeddings_refresh_worker.ex:113`

Verified safe today: ReqLLM error struct (`embed/2`, non-streaming) carries reason/status/response_body — no Authorization header. Streaming retry path includes response headers (provider headers, not request headers) — also safe.

Suggestion: add `# safe-to-log: verified ReqLLM error struct shape` comment, or wrap with `AdButler.Log.redact/1` to defend against a future ReqLLM bump that adds request headers.

### S3 — `filter_parameters` should include API-key keys
`config/config.exs:144-157`

Currently filters `password`, `access_token`, `client_secret`, `cloak_key`, etc. Add `"api_key"`, `"openai_api_key"`, `"anthropic_api_key"` as belt-and-braces.

### S4 — Mix task path-traversal not exploitable today, but undefended
`lib/mix/tasks/ad_butler.seed_help_docs.ex:48-63`

`Path.wildcard("priv/embeddings/help/*.md")` is rooted and doesn't follow `..`. Safe. If extended to accept a CLI `--dir`, wrap with `Path.safe_relative/2`.

---

## Verified Clean (one-line summaries)

- **Migrations** reversible; CHECK constraint on `kind` enforced at DB; HNSW `CONCURRENTLY` outside DDL transaction (correct).
- **Secrets**: `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` documented in `.env.example:62-67`, loaded via `System.fetch_env!` in `config/runtime.exs:60-64` (prod fails loudly). No hardcoded secrets.
- **SQL injection**: `nearest/3` pins `kind`, `pg_vector`, `limit` with `^`; positional fragment placeholders.
- **Atom exhaustion**: zero `String.to_atom` in any Week 8 file.
- **Tenant isolation in worker**: `EmbeddingsRefreshWorker` enumerates all ads/findings unscoped — acceptable for a global cron-driven backfill (CLAUDE.md tenant-scope rule applies to *user-facing* queries). Forward-looking risk is W1 above when chat consumes `nearest/3`.

---

## Recommended manual runs

- `mix sobelow --exit medium`
- `mix deps.audit`
- `mix hex.audit`
- `mix credo --strict`

**Counts: 0 BLOCKERS, 3 WARNINGS, 4 SUGGESTIONS.** Ship Week 8 — but treat W1 + W2 as release gates for the W9 chat-tool PR that first calls `Embeddings.nearest/3` from a user-facing surface.
