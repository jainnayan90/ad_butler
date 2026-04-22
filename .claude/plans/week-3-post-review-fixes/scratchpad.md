# Scratchpad: week-3-post-review-fixes

## Decisions

- **Oban snooze fix**: Use `{:snooze, {15, :minutes}}` tuple syntax (Oban 2.20+, we're on 2.21)
  rather than `15 * 60` — more readable and self-documenting.
  Test should assert literal `{15, :minutes}` value via pattern match.

- **PlugAttack dead rule**: Don't restore PlugAttack to :health_check pipeline (the B2 fix was
  correct — Fly probers share IPs). Instead: add an intent comment to the empty pipeline AND
  a comment to the dead PlugAttack rule to make it clear it is intentionally unreachable until
  a per-IP health limit is needed. Avoids re-introducing the machine restart loop.

- **Sentry safety**: Don't build a custom scrubber module (scope creep). Minimal safe config:
  `level: :error, capture_log_messages: false` on Sentry.LoggerBackend — this only captures
  exception-level events, not raw log strings, avoiding the known log-leak sites.
  Full scrubber is a separate RFC once Sentry is live.

- **hackney**: Remove the direct dep entirely. Sentry 10 uses httpc by default; hackney is
  optional and not explicitly configured.

- **Oban.insert_all changeset filter**: Remove the dead filter + comment entirely. The comment
  in the original code already noted DB errors raise. The `results` binding becomes unused,
  so revert to `Oban.insert_all(jobs)` with no binding.

## Dead Ends

(none yet)
