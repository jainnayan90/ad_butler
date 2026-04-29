# Scratchpad: week-2-auditor-review-fixes

## Decisions

- B1 fix: use `Enum.reduce_while` to stop on first health-score DB failure; return `{:error, reason}` so Oban retries the whole job. Idempotent via `get_unresolved_finding` dedup.
- B3: `Oban.insert_all/1` returns `{:ok, jobs}`, not a list — perform/1 can safely ignore the return and keep returning `:ok`.
- W3 split: `acknowledge_changeset/2` takes `user_id` (binary), not a user struct — avoids loading user in changeset.
- W1: Wire `send(self(), :reload_on_reconnect)` inside `if connected?(socket)` in mount; keep the handler.

## Risks / Dead Ends

- stalled_learning test: `updated_at` must be set manually via `Repo.insert` with explicit value or `Repo.update_all` after factory insert — ExMachina sets it to `now()`.
- cpa_explosion trigger: seed `insights_daily` rows with old `date_start` (within 30d), run mat view REFRESH, then seed recent high-spend rows. The setup block already does the REFRESH.
