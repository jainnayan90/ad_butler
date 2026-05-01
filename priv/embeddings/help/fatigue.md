# Creative fatigue

Creative fatigue is the decline in performance when the same creative has
saturated its target audience. The audience has seen the ad enough times
that incremental impressions yield fewer clicks and more wasted spend.

The Creative Fatigue Predictor blends four signals:

1. Frequency + CTR decay — frequency above 3.5 with falling CTR slope.
2. Quality-ranking drop — Meta's `quality_ranking` falling within 7 days.
3. CPM saturation — recent 7-day CPM up >20% vs prior week.
4. Predictive regression — projected CTR three days out below 60% of the
   ad's honeymoon baseline (only fires alongside one of the above three).

Each signal carries a weight. When the combined score crosses 50 the
predictor opens a `creative_fatigue` finding; >70 is high severity.
