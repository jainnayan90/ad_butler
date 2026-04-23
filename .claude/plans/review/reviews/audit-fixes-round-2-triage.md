# Triage: Audit Fixes Round 2 — 2026-04-22
**Source**: `.claude/plans/review/reviews/audit-fixes-round-2-review.md`

---

## Fix Queue

- [x] [W1] Remove dead `{:error, reason}` arm in `SyncAllConnectionsWorker` — bare insert + :ok
- [x] [W2] Fix `AMQPBasicBehaviour` ack/nack callback return specs — :ok | {:error, term()}
- [x] [W3] Add `is_map(body)` guard in `exchange_code/1` — + fallback clause with status
- [x] [W4] Add test for `{:cancel, "invalid_meta_connection_id"}` path — "not-a-uuid" test added
- [x] [W5] Replace `inspect(reason)` with `ErrorHelpers.safe_reason/1` at 3 sites — aliased + replaced
- [x] [S1] Strengthen orphan-drop test assertion — Repo.all + meta_id check added
- [x] [S2] Fix `plug_attack_test.exs` on_exit to use `delete_env` when original is nil
- [x] [S3] Prune unknown keys in `bulk_validate/2` — Map.take(known_fields) on valid entries

---

## Skipped

None.

## Deferred

None.
