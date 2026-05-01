# Acknowledging vs resolving findings

A finding has two states beyond "open":

- **Acknowledged** — you have read it and intend to look at it. The
  finding stays in the inbox but moves to the bottom of the priority list.
  Acknowledging is reversible: re-open and the finding returns to the top.
- **Resolved** — you have acted on it (paused the ad, raised the budget,
  swapped the creative). The finding leaves the open inbox.

The dedup unique index is partial (`WHERE resolved_at IS NULL`). Once you
resolve a finding for `(ad_id, kind)`, the next auditor pass can open a
new finding if the underlying signal is still present. Resolving is not
suppression.

If a finding is wrong (false positive), resolve it with a note. The
calibration team uses your resolution text to adjust thresholds.
