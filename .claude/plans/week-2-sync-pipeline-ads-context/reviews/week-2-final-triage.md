# Triage: Week 2 — Final Review (Round 3)
**Date**: 2026-04-22
**Source**: week-2-final-review.md

---

## Fix Queue

- [x] [NB3] ad_set_factory — campaign && campaign.ad_account used as ad_account fallback before build(:ad_account)
- [x] [NW5] ad_factory — NotLoaded guard added; falls back to build(:ad_account) for persisted ad_set structs
- [x] [NW6] publisher.ex — AMQP.Connection.close wrapped in try/catch :exit
- [x] [NW7] publisher.ex — handle_info(:DOWN) split into 3 clauses: conn_ref match, channel_ref match, stale ignore

---

## Skipped

(none)

---

## Deferred

- S1: Exchange name shared config (cosmetic, both modules hardcode same string)
- S2: timeout/1 callback in worker (low-priority suggestion)
- S3: Partial failure telemetry (observability improvement)
- W1–W10 from original review
