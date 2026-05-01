# Conversion tracking

Conversion counts come from the Meta pixel and Conversions API. The
InsightsConversionWorker pulls daily conversion counts every two hours
and writes them to `insights_daily.conversions` and
`conversion_value_cents`.

A few common gotchas:

- Attribution windows differ — Meta defaults to a 7-day click + 1-day view.
  A conversion attributed today may have happened any time in that window.
- The pixel can lag — it can take an hour or two for events to land.
- iOS 14+ users with App Tracking off do not show in standard pixel data.

Use the conversion column for trend, not exact attribution. If your
internal funnel reports 30% fewer conversions than Meta, that is normal
and expected.
