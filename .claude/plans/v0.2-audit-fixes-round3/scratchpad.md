# Scratchpad — Audit Fixes Round 3

## Key decisions

- W3 (Jason.encode!): `Jason.encode!/1` rarely fails in practice on these structs (UUIDs + integers), but using `Jason.encode/1` + case is the correct pattern per CODING_PRINCIPLES. Filter nil results before publishing.
- W4 (analytics spec): Prefer changing spec to `:: :ok | no_return()` rather than wrapping in rescue — `Repo.query!` is intentionally bang; the spec was just wrong. Add a @doc note that DB failures raise.
- W6 (bulk_upsert rescue): Return `{:error, :upsert_failed}` atom + log at rescue site. Do NOT propagate raw exception struct.
- W7 (idempotency): Document in @moduledoc that downstream consumers must be idempotent — RabbitMQ fan-out with retries is inherently at-least-once. No code change needed.
- W8 (timeout): Add `def timeout(_job), do: :timer.minutes(6)` — just above the 5-minute DB transaction timeout in stream_ad_accounts_and_run.
- S4 (CI grep): Use a mix alias rather than a custom Credo check — simpler, no Credo DSL needed. Add to mix.exs `precommit` alias.

## Dead-ends

None yet.
[18:56] WARN: elixir-reviewer did not write .claude/plans/v0.2-audit-fixes-round3/reviews/elixir.md — extracted from agent message
[18:56] WARN: iron-law-judge did not write .claude/plans/v0.2-audit-fixes-round3/reviews/iron-laws.md — extracted from agent message
[18:56] WARN: oban-specialist did not write .claude/plans/v0.2-audit-fixes-round3/reviews/oban.md — extracted from agent message
[21:05] WARN: elixir-reviewer did not write elixir-pass2.md — extracted from message
[21:05] WARN: oban-specialist did not write oban-pass2.md — extracted from message
[21:05] WARN: iron-law-judge did not write iron-laws-pass2.md — extracted from message
