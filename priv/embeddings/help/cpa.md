# What is CPA?

CPA is cost per acquisition: total ad spend divided by the number of
conversions reported by the pixel. CPA is the conversion-objective ad's
truth — when CPA blows past target, the campaign is losing money on every
new customer.

Watch the CPA trend, not the absolute number. A $40 CPA is fine if the
customer LTV is $200 and the trailing CPA was $35. The same $40 CPA is a
five-alarm fire if last week was $12.

The `cpa_explosion` finding fires when the recent 7-day CPA exceeds the
prior 28-day baseline by a configurable margin (default 50%). The first
fix is typically tightening the audience, raising the bid floor, or
pausing the worst-performing ad in the set.
