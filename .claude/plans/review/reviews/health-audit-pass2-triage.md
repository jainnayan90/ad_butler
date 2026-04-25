# Triage: health-audit-findings-apr23 — Pass 2

**Date:** 2026-04-25
**Source:** health-audit-pass2-review.md

---

## Fix Queue

- [x] **W-N1** — `token_refresh_sweep_worker.ex:37` — Replace `length(raw) > @default_limit` + `Enum.take(raw, @default_limit)` with `Enum.split(raw, @default_limit)` — one pass instead of two
- [x] **W-N2** — `token_refresh_sweep_worker.ex:61` — Drop the dead atom-key fallback `|| &1.args[:meta_connection_id]`; use `& &1.args["meta_connection_id"]` only (Oban always returns string keys after JSON round-trip)
- [x] **W-N3** — `token_refresh_sweep_worker.ex:75` — Guard `Logger.info` with `if total > 0` to suppress log noise on no-op sweeps
- [x] **W-N4** — `plug_attack_test.exs:unique_octet/0` — Add inline comment: `# for readability only — isolation is guaranteed by the ETS flush in setup`

---

## Skipped

- S-N1: Repo.aggregate deprecated field arg — deferred
- S-N2: ObanMock stub comment — deferred
- S-N3: Tighten skipped comment — deferred
- S-N4: capture_log test for skipped-warning path — deferred
