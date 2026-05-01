# Reading findings

A finding is one signal from one auditor about one ad. The system writes a
finding when its analyzer is confident enough that something is worth your
attention. Each finding carries:

- `kind` — what was detected (dead_spend, cpa_explosion, creative_fatigue, …)
- `severity` — low / medium / high; high finds are worth investigating today
- `evidence` — the numbers behind the call (spend, conversions, slope, etc.)
- `body` — short explanation in plain English

Findings dedup on `(ad_id, kind)` while unresolved — a second run of the
auditor on the same ad will not stack identical findings. Acknowledging a
finding marks "I saw this"; resolving it marks "I acted on it."
