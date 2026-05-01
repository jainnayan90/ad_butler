# Honeymoon baseline

The honeymoon baseline is the ad's CTR average over its first three days
with more than 1000 impressions per day. The predictor uses this as the
"healthy" reference point — projected CTR three days out below 60% of
the honeymoon baseline contributes to the predicted-fatigue signal.

The baseline is computed once and cached on `ad_health_scores.metadata`,
then reused across runs. If the baseline is ever clearly wrong (an ad
launched into the wrong audience, then was repointed), purge the cache
manually and let the next audit recompute.

For ads that never crossed 1000 impressions in any single day during
their first weeks, the predictor cannot establish a baseline and the
predictive layer stays silent — heuristic signals continue to fire on
their own.
