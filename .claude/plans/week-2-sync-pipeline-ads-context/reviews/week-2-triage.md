# Triage: Week 2 — Sync Pipeline & Ads Context
**Date**: 2026-04-22
**Source**: week-2-review.md

---

## Fix Queue

- [x] [B1] Publisher.init/1 — lazy connect via send(self(), :connect); init returns {conn: nil, channel: nil, ...}; handle_call guards nil channel
- [x] [B2] Monitor channel.pid in addition to conn.pid; store conn_ref + channel_ref in state; demonitor on reconnect; @impl GenServer on first handle_info
- [x] [B3] sync_account/2 uses with/else to return {:error, reason} on upsert or publish failure; perform/1 collects results with Enum.map and returns first error
- [x] [B4] Added unique: [period: 300, keys: [:meta_connection_id]] to FetchAdAccountsWorker
- [x] [B5] ad_set_factory now builds ad_account first, then campaign with that ad_account — default factory state is always consistent

---

## Skipped

- W1–W10: Deferred — not blocking production readiness
- S1–S8: Deferred — cosmetic/nice-to-have

---

## Deferred

- W1: Scheduler one-shot (replace GenServer with Oban Cron or add reschedule)
- W2: N+1 query in handle_batch
- W3: Aggressive :cancel on first 401
- W4: Unvalidated UUID in handle_message
- W5: parse_budget raises on non-integer strings
- W6: Unbounded list_all_active_meta_connections
- W7: AMQP credential leak via inspect
- W8: Sandbox.allow gap in scheduler test
- W9: DLQ replay poison messages
- W10: Process.sleep in integration test
