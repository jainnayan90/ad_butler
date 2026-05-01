# Security Review — v0.3 + week8 fixes

⚠️ EXTRACTED FROM AGENT MESSAGE — agent could not write directly (hook-restricted).

**Counts:** 0 BLOCKERS, 2 WARNINGS, 3 SUGGESTIONS. Ship W8. WARN-1 + WARN-2 are release gates for the first W9 user-facing caller of `Embeddings.nearest/3`.

## Executive Summary

W8 hardening landed cleanly: kind allowlist guards (`@valid_kinds`), `@max_nearest_limit 50` clamp, behaviour-bounded service, content_hash hex regex, explicit `unsafe_*` naming on every internal helper, and documented intentional cross-tenant invariant. No BLOCKERs.

---

## WARNINGS

**WARN-1 — `lib/ad_butler/embeddings.ex:104-116`**

`nearest/3` is intentionally cross-tenant (doc'd at `:1-12`). A W9 chat tool that renders returned `ref_id`s or `content_excerpt`s without first intersecting against `Ads.list_ad_account_ids_for_user/1` (or `Analytics.get_finding/2`) leaks another tenant's data.

→ Release gate for the first W9 PR that calls `Embeddings.nearest/3`. Resolve `ref_id`s back through the tenant-scoped context and drop `:not_found` rows. `kind="doc_chunk"` is exempt (admin-curated, global). Suggest a `Chat.tenant_filter_embedding_results/2` helper so individual tools can't forget.

**WARN-2 — `lib/ad_butler/workers/embeddings_refresh_worker.ex:91-93,167-176` + `lib/ad_butler/embeddings/embedding.ex:17-19`**

Ad `content_excerpt` is `"<ad.name> | <creative.name>"` (first 200 chars). Schema docstring forbids "user-typed PII" but **advertiser ad names are third-party-typed strings** that occasionally carry customer names or internal codenames. Today no user-facing path reads excerpts cross-tenant, so this is latent.

→ When W9 renders kNN results, drop `content_excerpt` for non-`doc_chunk` rows (or only show it after the tenant filter passes). Tighten schema docstring to acknowledge advertiser-typed labels.

---

## SUGGESTIONS

**SUG-1 — `lib/mix/tasks/ad_butler.seed_help_docs.ex:47-63`**

Task globs `priv/embeddings/help/*.md` (verified: 13 curated files, no user-upload paths). Defense-in-depth: wrap with `Path.safe_relative/2` against `Application.app_dir(:ad_butler, "priv/embeddings/help")` so a future symlink can't pull arbitrary files into `kind="doc_chunk"`. Low priority.

**SUG-2 — `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:489-494`**

Logs `reason: changeset.errors` from `Analytics.create_finding/1`. Verified safe: `Finding.create_changeset/2` (`lib/ad_butler/analytics/finding.ex:46-47`) casts only `[:ad_id, :ad_account_id, :kind, :severity, :title, :body, :evidence]` — no token/PII fields, `title`/`body` are worker-rendered.

→ Add inline comment `# safe: Finding has no token/PII fields` so a future schema add must re-audit.

**SUG-3 — `config/config.exs:146-162`**

`:filter_parameters` correctly adds `"api_key"`, `"openai_api_key"`, `"anthropic_api_key"`. Logger metadata adds `:ref_id` (deterministic UUID, never user-typed) and `:vectors_received` (integer). Both non-sensitive. → No fix; confirming.

---

## Iron Law Pass

Atom exhaustion (`String.to_atom`), `raw/1`, `:erlang.binary_to_term`, SQL injection (fragments parameterized — `nearest/3` uses `^pg_vector`/`^kind`/`^capped`), Repo boundary (`bulk_upsert` keeps `insert_all` inside context), tenant scope on user-facing `Analytics` reads (`scope_findings/2` at `analytics.ex:905-908`), secrets-in-code (loaded via `System.fetch_env!` in `runtime.exs:60-64`): all clean.

## Manual Tools

User should run: `mix sobelow --exit medium`, `mix deps.audit`, `mix hex.audit`.
