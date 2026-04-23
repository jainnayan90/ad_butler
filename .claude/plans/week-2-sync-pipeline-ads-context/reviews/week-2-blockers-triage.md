# Triage: Week 2 — Blocker Fixes Follow-up
**Date**: 2026-04-22
**Source**: week-2-blockers-review.md

---

## Fix Queue

- [x] [NB1] ad_set_factory — attrs-based pattern; ad_account resolved first, campaign derived from it
- [x] [NB2] ad_factory — same attrs-based pattern; ad_set resolved first, ad_account derived from it
- [x] [NW1] publisher.ex — Channel.open wrapped in case; AMQP.Connection.close/1 called on failure before retry
- [x] [NW2] fetch_ad_accounts_worker.ex — Jason.encode!/1 → Jason.encode/1 as with clause
- [x] [NW3] fetch_ad_accounts_worker.ex — unique states excludes :completed (re-triggers allowed after success)
- [x] [NW4] fetch_ad_accounts_worker.ex — get_meta_connection/1 with nil → {:cancel, "meta_connection_not_found"}; test added

---

## Skipped

(none)

---

## Deferred

- S1–S4 from blockers review
- W1–W10 from original review
