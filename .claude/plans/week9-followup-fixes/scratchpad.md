# Scratchpad: week9-followup-fixes

## Dead Ends (DO NOT RETRY)

(none yet)

## Review Logs

- 2026-05-02 12:30 — WARN: elixir-reviewer agent did not write `.claude/plans/week9-followup-fixes/reviews/elixir.md` (reported tool permission issue). Orchestrator captured the agent's chat-message output verbatim and wrote it to the file with an EXTRACTED FROM AGENT MESSAGE banner.
- 2026-05-02 12:34 — WARN: testing-reviewer agent did not write `.claude/plans/week9-followup-fixes/reviews/testing.md` (Write tool blocked). Orchestrator captured chat output verbatim and wrote with EXTRACTED FROM AGENT MESSAGE banner.
- 2026-05-02 12:38 — WARN: security-analyzer agent did not write `.claude/plans/week9-followup-fixes/reviews/security.md` (Write tool denied). Orchestrator captured chat output verbatim and wrote with EXTRACTED FROM AGENT MESSAGE banner.
- 2026-05-02 14:18 — WARN: elixir-reviewer (post-triage) did not write `.claude/plans/week9-followup-fixes/reviews/elixir-post-triage.md` (Write tool denied). Orchestrator captured chat output verbatim and wrote with EXTRACTED FROM AGENT MESSAGE banner.
- 2026-05-02 14:19 — WARN: testing-reviewer (post-triage) did not write `.claude/plans/week9-followup-fixes/reviews/testing-post-triage.md` (Write tool denied). Orchestrator captured chat output verbatim and wrote with EXTRACTED FROM AGENT MESSAGE banner.
- 2026-05-02 14:50 — WARN: testing-reviewer (final cross-cutting pass) did not write `.claude/plans/week9-final/reviews/testing.md` (Write tool denied). Orchestrator captured chat output verbatim and wrote with EXTRACTED FROM AGENT MESSAGE banner.
- 2026-05-02 14:55 — WARN: elixir-reviewer (final pass) Write denied; captured inline output to `.claude/plans/week9-final/reviews/elixir.md`.
- 2026-05-02 14:56 — WARN: iron-law-judge (final pass) Write denied; captured inline output to `.claude/plans/week9-final/reviews/iron-laws.md`.
- 2026-05-02 14:57 — WARN: security-analyzer (final pass) ran out of turns mid-investigation. Captured the partial output (1 unverified claim) to `.claude/plans/week9-final/reviews/security.md`. Orchestrator independently verified the claim by reading `lib/ad_butler/chat/system_prompt.ex`, `lib/ad_butler/chat/server.ex:445-452`, and `grep -rn SystemPrompt lib/ test/` (no callers). VERIFIED BLOCKER: SystemPrompt is loaded but never wired into Chat.Server's LLM request — prompt-injection guardrails in priv/prompts/system.md never reach the model.

## Decisions

### D-FU-01 — Test W resolved by inspection

`chat_messages.inserted_at` is `:utc_datetime_usec` in BOTH the migration
([priv/repo/migrations/20260501110604_create_chat_messages.exs#L18](priv/repo/migrations/20260501110604_create_chat_messages.exs#L18))
and the schema ([message.ex:34](lib/ad_butler/chat/message.ex#L34)).
`insert_chat_message_at/4` sub-second offsets are NOT truncated. No code change.

### D-FU-02 — `kind_of/1` instead of `inspect(other)` in tool-call fallback

CLAUDE.md bans `inspect/1` in Logger metadata. The fallback path also banned
it from jsonb (Sec W-4). Logging `kind_of(other)` (a 3-class atom: "map",
struct name, "other") gives observability without leaking the term's
contents — a malformed tool call could in principle carry user-typed text.

### D-FU-03 — Grep gate over `Chat.Internal` module

Considered: move `unsafe_get_session_user_id/1` and
`unsafe_flip_streaming_messages_to_error/1` into `AdButler.Chat.Internal`
so the public `AdButler.Chat` API never exposes them. Rejected because:

- The grep alias is one-line, runs in CI on every precommit, and gives
  the same enforcement.
- A separate module imports complexity for two functions.
- The functions are still callable from inside `lib/ad_butler/chat/server.ex`
  via the existing `alias AdButler.Chat`; an Internal module would force
  an extra alias everywhere.

If W11 adds more `unsafe_*` functions, revisit and consider the move.

## Open Questions

(none — all guidance carries forward from the triage)

## Handoff

All 5 phases landed. 529 tests / 0 failures. `mix check.unsafe_callers` and
`mix check.tools_no_repo` both green; credo --strict shows only the
pre-existing `compare_creatives.ex` TODO suggestion (W11 follow-up, out of
scope). `mix precommit` as a single alias trips on `hex.audit` resolution
(pre-existing on main; each precommit step passes individually).

Review output (elixir-reviewer + security-analyzer) flagged one warning —
`grep --exclude=basename` in the `check.unsafe_callers` alias would let a
future `lib/foo/server.ex` slip through. Fixed by extracting the gate to
`scripts/check_chat_unsafe.sh` with path-anchored `grep -v '^lib/...:'`.

Two solution docs captured:
- `.claude/solutions/build-issues/grep-exclude-basename-bypasses-path-gate-20260502.md`
- `.claude/solutions/ecto/jason-encode-bang-on-tool-results-crashes-genserver-20260502.md`

Two security findings deferred to W10/W11 (out of scope for this plan):
- `request_id` in the Telemetry process-dictionary context is not
  redacted; consider wrapping in a struct with `@derive {Inspect, except:
  [:request_id]}`.
- `Chat.append_message/1` could use `on_conflict: :nothing,
  conflict_target: [:request_id]` for assistant rows to make legitimate
  retries silent (currently raises `Ecto.ConstraintError`, which is the
  intended behavior for now — flag in W11 if a real retry path lands).
