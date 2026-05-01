# Finding severity

Findings carry a severity bucket so you can triage. The mapping is
calibrated to wasted-spend impact:

- `low` — informational; the analyzer noticed something worth flagging
  but nothing is on fire.
- `medium` — actionable today; left alone for a week the issue would
  cost real money.
- `high` — actionable now; spend is being wasted at a meaningful daily
  rate.

For Creative Fatigue, severity is keyed to the combined fatigue score:
50–69 → medium, 70+ → high. For Budget Leak, severity comes from the
specific heuristic that fired and its absolute spend impact.

The Findings inbox lists by `inserted_at desc` by default. Filter by
severity in the dropdown to triage today's high-impact items first.
