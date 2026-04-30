---
module: "AdButler.Workers.CreativeFatiguePredictorWorker (and any Logger call site)"
date: "2026-04-30"
problem_type: anti_pattern
component: logging
symptoms:
  - "Logger.error metadata field comes through to log aggregator (Loki/Datadog) as a string blob like `\"%{kind: {\\\"has already been taken\\\", [...]}}\"` instead of a structured field"
  - "Filtering or grouping log lines by error reason in the aggregator becomes impossible — every distinct term renders to a unique string"
  - "Debugging an audit failure requires re-parsing the inspect output by eye instead of querying on a normal field"
  - "Code reviewers flag `reason: inspect(reason)` as a CLAUDE.md / Iron Law #8 violation"
root_cause: "Pre-stringifying terms via `inspect/1` inside a structured KV Logger call collapses the term into a single string field, defeating the structured-logging contract. The Elixir Logger backend is capable of serializing arbitrary terms when the formatter (or the downstream JSON shipper) handles them — passing a raw term preserves searchable structure. `inspect/1` is appropriate inside the *message string* (where structure has already been lost), or for terms the formatter genuinely cannot handle (PIDs, refs, anonymous fns), not for plain maps/keyword lists/changeset-error tuples that the Logger metadata pipeline already serializes correctly."
severity: medium
tags: [logging, observability, iron-law-8, structured-logging, inspect, ecto-changeset, ad-butler]
---

# Logger.error reason: inspect(...) Defeats Structured Aggregation

## Symptoms

A worker logs an error with the project's structured-KV pattern:

```elixir
Logger.error("creative_fatigue_predictor: audit failed",
  ad_account_id: ad_account.id,
  reason: inspect(reason)
)
```

The downstream log aggregator receives `reason` as a single string field
containing the inspect output of whatever the term was. Filtering on
`reason="not_found"` or `reason.kind="..."` no longer works — every term
serializes to a different string, even when they're semantically identical.

## Investigation

1. **Read CLAUDE.md "Logging and Observability"** — mandates structured KV,
   never string interpolation, never secrets/PII. Says nothing explicit about
   `inspect/1` because the rule is implicit: the *whole point* of KV metadata
   is preserving term structure.
2. **Read `config/config.exs` Logger metadata allowlist** — `:reason` is
   allowed. The formatter can render any allowlisted term that has a sensible
   `Inspect`/`String.Chars` impl.
3. **Trace the Ecto changeset case** — `changeset.errors` is a keyword list of
   `{field, {message, opts}}` tuples. The Logger formatter can serialize
   keyword lists fine; collapsing it to a string via `inspect/1` is gratuitous.
4. **The original worry** — "but `reason` could be `%Postgrex.Error{}` or some
   weird struct" — is valid only for genuinely non-serializable terms. For
   atoms, maps, keyword lists, structs with derived `Inspect`, the formatter
   handles them correctly and the aggregator preserves the field shape.

## Root Cause

`inspect/1` is for converting a term into a *string for human reading inside a
message body*. The Logger metadata pipeline expects the *raw term* and applies
the formatter once at the boundary to the log shipper. Passing `inspect(term)`
makes it a string twice — once in your code, once in the formatter — and the
aggregator only sees the final string.

## Solution

### Replace `inspect/1` with the raw term

```elixir
# Before
Logger.error("creative_fatigue_predictor: audit failed",
  ad_account_id: ad_account.id,
  reason: inspect(reason)
)

# After
Logger.error("creative_fatigue_predictor: audit failed",
  ad_account_id: ad_account.id,
  reason: reason
)
```

### For changeset errors specifically, pass `changeset.errors`

```elixir
# Before
Logger.error("finding creation failed",
  ad_id: ad_id, kind: "creative_fatigue",
  reason: inspect(changeset.errors)
)

# After
Logger.error("finding creation failed",
  ad_id: ad_id, kind: "creative_fatigue",
  reason: changeset.errors
)
```

The keyword list of `{field, {message, opts}}` tuples is preserved in the
aggregator — you can filter on `reason.kind` to find every "kind has already
been taken" event across all workers.

### When `inspect/1` IS appropriate

Inside the *message string* itself, where structure was already going to be
lost, you can use it freely:

```elixir
Logger.warning("unexpected payload shape: #{inspect(payload)}", request_id: id)
```

That's a freeform debug message; the structured field is `request_id`, not the
inspect output.

### Files Changed

- `lib/ad_butler/workers/creative_fatigue_predictor_worker.ex:236, 354, 365` —
  three `Logger.error` calls switched to raw `:reason` term.

## Prevention

- [ ] **`reason: inspect(...)` is a smell** — always passes a raw term to a
      structured logger metadata field. Reviewer-flag in `/phx:review`.
- [ ] **Confirm `:reason` (or whatever metadata key) is in the
      `config/config.exs` Logger metadata allowlist** before relying on it.
      Allowlist gating is the project's contract for what reaches the log
      backend.
- [ ] **For changeset errors, pass `changeset.errors` (the keyword list).**
      It's serializable and queryable. Don't pass the whole `%Ecto.Changeset{}`
      — it carries the entire schema and balloons the log line.
- [ ] **Reserve `inspect/1` for**: (1) the message string itself, (2) terms
      with non-serializable internals (PIDs, refs, large binaries), or (3)
      genuinely opaque tuples where the structure is meaningless to the
      aggregator anyway.

## Iron Law

**Iron Law #8 (Logging and Observability)** — structured KV, never collapse
the term to a string at the call site.

## Related

- CLAUDE.md "Logging and Observability"
- `config/config.exs` Logger metadata allowlist
- `.claude/solutions/oban/dedup-via-mapset-and-unique-constraint-backstop-20260430.md`
  (its example code at line 110 uses `inspect/1` — would be cleaner now;
  the lesson here generalizes)
- Plan: `.claude/plans/week7-fixes/reviews/week7-pass4-triage.md` (W-4 fix)
