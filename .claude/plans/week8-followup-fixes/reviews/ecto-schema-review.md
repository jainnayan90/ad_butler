# Ecto Schema Designer Findings — week8-followup-fixes

Reviewer: elixir-phoenix:ecto-schema-designer
Status: No correctness issues

## Verified clean

### `belongs_to :ad` with `@foreign_key_type :binary_id`
`ad_health_score.ex:23,26` — correct. Module-level default applies to every `belongs_to`. Ecto infers `:ad_id` as FK column with type `:binary_id`, matching DB column. `foreign_key_constraint(:ad_id)` is the right companion call.

### `field :inserted_at, :utc_datetime_usec` without `updated_at`
`ad_health_score.ex:36` — fine as deliberate append-only design. Note: Ecto won't auto-populate; verify either DB DEFAULT or explicit cast at write sites.

**VERIFIED:** DB has `default: fragment("NOW()")` at `migrations/20260427000001_create_ad_health_scores.exs:14`. Reads will not return nil.

### Amending the unreleased migration
`20260501000002_create_embeddings.exs` — correct approach. CLAUDE.md rule is "migrations are append-only in shared environments." Unreleased = not in staging/prod, so amending in place is right. Adding follow-up migration for `null: false` on a brand-new column would be unnecessary churn.

### `@timestamps_opts` promotion
`embedding.ex:39` — purely conventional, no correctness change.

## Triage outcome

All findings verified clean. No action needed.
