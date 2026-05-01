# What is budget leak?

Budget leak describes spend that is unlikely to convert. The Budget Leak
Auditor runs every six hours and emits findings when an ad falls into one
of the bot/dead-spend patterns:

- `dead_spend` — significant spend without conversions over a defined window.
- `cpa_explosion` — recent CPA dramatically exceeds the trailing baseline.
- `bot_traffic` — abnormal click-to-impression ratios (suggests non-human).
- `placement_drag` — one Meta placement is dragging the average down.
- `stalled_learning` — ad set stuck outside the learning-phase exit criteria.

Each pattern has its own threshold. Fixes range from tightening the audience
or budget (CPA explosion), to pausing/replacing creatives (dead spend),
to removing problematic placements (placement drag).
