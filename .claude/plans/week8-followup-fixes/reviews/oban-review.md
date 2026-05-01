# Oban Specialist Findings — week8-followup-fixes (Round 2 — post-B1 fix)

Reviewer: elixir-phoenix:oban-specialist
Status: B1 RESOLVED — no new findings

## B1 — Snooze comment now correct

`lib/ad_butler/workers/embeddings_refresh_worker.ex:168-176`

Re-verified against `deps/oban/lib/oban/engines/basic.ex:263-272`:

- File/line reference cited in comment — correct.
- Mechanism `inc: [max_attempts: 1]` — confirmed verbatim at line 266.
- Conclusion "snoozes do NOT consume retry budget" — correct. The `inc: [max_attempts: 1]` compensates for the attempt counter bump at job start; net effect on remaining retries is zero.
- Implication "`max_attempts: 3` covers three genuine error retries independent of snooze count" — correct.

No new inaccuracy introduced. The comment is a precise, source-cited explanation.

## Round 1 findings status

- B1 (BLOCKER snooze comment): **RESOLVED** ✓
- timeout/1 at 5 minutes: clean (light Round-1 suggestion to consider 10 min for worst-case embed latency — non-blocking).
- Idempotency via `(kind, ref_id)` upsert: clean.

## Verdict

PASS. B1 closed.
