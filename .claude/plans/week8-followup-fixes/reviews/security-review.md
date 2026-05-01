# Security Analyzer Findings — week8-followup-fixes

Reviewer: elixir-phoenix:security-analyzer
Status: 0 Blockers, 1 Warning, 2 Suggestions — SHIP IT

## Warning

### W1 — `scrub_for_user/1` is convention-only; chain not enforceable

`lib/ad_butler/embeddings.ex:128-142, 226-232`

`nearest/3` returns raw `[Embedding.t()]` with `content_excerpt` populated. A future Week-9 chat tool can call `nearest/3` and render rows directly, bypassing both `tenant_filter_results/2` and `scrub_for_user/1`. The moduledoc warns, but Iron Law 4 favors structural enforcement.

**Mitigation options for W9 chat-tool PR (release gate, not blocker today):**
1. Make `nearest/3` accept `%User{}` and return scrubbed+filtered rows by default; expose `nearest_unscoped/3` for admin/test callers (audit-greppable opt-out).
2. Or, change return type to wrapper `{:raw, [Embedding.t()]}` so callers must explicitly destructure — "I forgot to scrub" becomes a Dialyzer signal.

Verified ZERO non-test callers today (`grep Embeddings.nearest lib/` empty). DEFER — track on W9 chat-tool PR.

## Suggestions

### S1 — `Path.safe_relative/2` usage is correct

`lib/mix/tasks/ad_butler.seed_help_docs.ex:57-59`

First arg `Path.relative_to(path, base)` (relative), second arg `base` (cwd). Matches Elixir 1.14+ contract. Mix-task admin context limits real attack surface; defense appropriate for "future symlink in priv/embeddings/help" threat. NO CHANGE.

### S2 — `tenant_filter_results/2` raise leaks kind via `inspect/1`

`lib/ad_butler/embeddings.ex:197-201`

Low risk (kind is from `Embedding.kinds/0` allowlist + DB CHECK constraint). Branch unreachable in prod. If it ever fires, kind ends up in error trackers. Consider `Logger.error/2` with metadata + raise constant message — aligns with CLAUDE.md "structured logging, never interpolation."

## Verified clean

- `belongs_to :ad` on `AdHealthScore` preserves tenant scoping.
- Migration `null: false` on `:embedding` is pure integrity tightening.
- Recommended manual checks: `mix sobelow --exit medium`, `mix deps.audit`.

## Triage outcome

- W1: DEFER to Week-9 chat-tool PR (not in current scope).
- S1: VERIFIED CORRECT.
- S2: SKIP — pre-existing code (not modified in this PR), not in scope.
