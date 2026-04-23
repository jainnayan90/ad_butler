# Triage: Publisher/Health Review — 2026-04-23

## Fix Queue

- [ ] **B1**: health_controller_test.exs — bust `:persistent_term` cache before 503 test
- [ ] **B2**: publisher.ex — add `await_connected/0` public API; use it in publisher_test.exs setup
- [ ] **W1**: publisher.ex:101 — replace 4-key pattern match in `terminate/2` with `Map.get`

## Skipped

- **W2**: persistent_term thundering herd — acceptable for Fly probe cadence; document assumption if desired
- **W3**: Topology test comment overstates DLX coverage — cosmetic

## Deferred

None
