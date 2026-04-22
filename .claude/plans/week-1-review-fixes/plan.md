# Plan: Week 1 Review Fixes

**Source**: `.claude/plans/week-1-days-2-to-5/reviews/week-1-days-2-to-5-triage.md`  
**Findings**: 7 BLOCKERs · 10 WARNINGs · 11 SUGGESTIONs (28 total)  
**Phases**: 5 · **Tasks**: 28

---

## Phase 1: Security — AuthController [5 tasks]

> Fix session fixation, timing-unsafe state comparison, state replay, and magic number.
> All changes isolated to `auth_controller.ex` and `config/config.exs`.

- [x] [P1-T1] **B5** Replace `==` with `Plug.Crypto.secure_compare/2` in `verify_state/2`; delete `:oauth_state` from session after verification — `verify_state` now returns `{:ok, conn}` with key deleted
- [x] [P1-T2] **B6** Add `configure_session(conn, renew: true) |> clear_session()` before `put_session(:user_id, user.id)` in callback success path; add `live_socket_id: "users_sessions:#{user.id}"` — done
- [x] [P1-T3] **W3** Extract `60 * 24 * 60 * 60` to `@meta_long_lived_token_ttl_seconds` module attribute — done
- [x] [P1-T4] **W4a** Add `config :phoenix, :filter_parameters, [...]` to `config/config.exs` — done
- [x] [P1-T5] **W4b** Replace `inspect(reason)` with structured field extraction in `auth_controller.ex` Logger call — added `log_safe_reason/1` helper

---

## Phase 2: Oban Worker [7 tasks]

> Fix correctness issues in `token_refresh_worker.ex`: hard match crash, duplicate chains,
> permanent vs transient error handling, deleted connection retry, timeout, and observability.
> Also updates `meta_connection.ex` to add `:revoked` status (required by W1).

- [x] [P2-T1] **B1** Replace `{:ok, _} = Accounts.update_meta_connection(...)` with `case`; call `schedule_next_refresh` only on `{:ok, _}`; return `{:error, :update_failed}` on error — done in `do_refresh/2`
- [x] [P2-T2] **B7** Add `unique: [period: {23, :hours}, keys: [:meta_connection_id]]` to `use Oban.Worker` options — done
- [x] [P2-T3] **W1** Add permanent error handling: `{:cancel, reason}` for `:unauthorized`/`:token_revoked`; `{:snooze, 3600}` for rate-limit — done
- [x] [P2-T4] **W2** Replace `get_meta_connection!/1` with `get_meta_connection/1`; add nil guard returning `{:cancel, "connection not found"}` — added `get_meta_connection/1` to `Accounts`
- [x] [P2-T5] **W7** Add `@impl Oban.Worker; def timeout(_job), do: :timer.seconds(30)` — done
- [x] [P2-T6] **S10** Add inline comment on `expires_in` units assumption — done
- [x] [P2-T7] **S11** Attach Oban telemetry handler for `[:oban, :job, :stop]` + `[:oban, :job, :exception]` in `application.ex` — done
- [x] [P2-T8] **W1-dep** `"revoked"` already in `validate_inclusion` in `meta_connection.ex` — confirmed, no change needed

---

## Phase 3: Data & Client Layer [6 tasks]

> Fix ETS PII leak (B2), account takeover upsert (B3), redact token (W5),
> and clean up client.ex (S8, S9). Also fix W4b for worker logger call.

- [x] [P3-T1] **B2** Thread actual `ad_account_id` through `parse_rate_limit_header/2`: added `ad_account_id:` opt to `make_request`; updated `list_campaigns/list_ad_sets/list_ads` callers; added pruning note to `rate_limit_store.ex`
- [x] [P3-T2] **B3** Change `conflict_target: :email` to `conflict_target: :meta_user_id`; `on_conflict` updated — also created migration `20260421000001` to fix non-unique index on `meta_user_id`
- [x] [P3-T3] **W5** Add `redact: true` to `field :access_token, AdButler.Encrypted.Binary` — done
- [x] [P3-T4] **W4c** Replace `inspect(reason)` with structured logging in worker — done in P2 rewrite (no `inspect` calls)
- [x] [P3-T5] **S7** Replace `MetaConnection.changeset(Map.put(attrs, :user_id, user.id))` with struct-first pattern — done
- [x] [P3-T6] **S8+S9** Remove `elem_or_nil/2` helper; collapse duplicate `with` branches in `parse_rate_limit_header/2` — done

---

## Phase 4: Config & Infrastructure [4 tasks]

> Move HTTP calls from AuthController to Meta.Client (W6), add Oban plugins (W8),
> deduplicate req_options (S1).

- [x] [P4-T1] **W6** Move `exchange_code_for_token/1` and `fetch_user_info/1` into `AdButler.Meta.Client` as `exchange_code/3` and `get_me/1`; updated `AuthController`; updated test to stub via `AdButler.Meta.Client`
- [x] [P4-T2] **S1** Remove duplicated `req_options/0` from `auth_controller.ex` — done (controller no longer makes raw Req calls)
- [x] [P4-T3] **W8** Add Oban Lifeline and Pruner plugins to Oban config in `config/config.exs` — done
- [x] [P4-T4] **Atom keys** Change `%{meta_connection_id: ...}` to `%{"meta_connection_id" => ...}` in `schedule_refresh/2` — done in P2 rewrite

---

## Phase 5: Tests [6 tasks]

> Fix critical encryption test (B4), tighten existing assertions (W9, W10),
> fix factory issues (S2, S3), clean up ETS/Mox issues (S4, S5), add sad-path coverage (S6).

- [x] [P5-T1] **B4** Fix encryption test: `Repo.query!("SELECT encode(access_token, 'escape')...")` with `Ecto.UUID.dump!` for UUID param; assert raw != plaintext — done
- [x] [P5-T2] **W9** Add `args: %{"meta_connection_id" => conn.id}` to `assert_enqueued` call — done
- [x] [P5-T3] **W10** Replace hardcoded `"test@example.com"` with `System.unique_integer`-based email — done
- [x] [P5-T4] **S2+S3** Fix factory: rename `:meta_user_id` sequence to `:mc_meta_user_id`; replace `System.unique_integer` with `sequence(:access_token, ...)` — done
- [x] [P5-T5] **S4+S5** Add `on_exit` ETS cleanup in `client_test.exs`; add `setup :set_mox_from_context` to `token_refresh_worker_test.exs` — done
- [x] [P5-T6] **S6** Added sad-path tests: duplicate meta_connection constraint, invalid status update, non-existent connection cancel, token exchange 4xx — done

---

## Verification (per phase)

After each phase: `mix compile --warnings-as-errors && mix format --check-formatted`  
After Phase 2 + 5: `mix test test/ad_butler/workers/` and `mix test test/ad_butler/`  
Final gate: `mix test` (full suite) — **31 tests, 0 failures** ✓

---

## Risks

1. **W6 (move HTTP to Meta.Client)** changes the `Req.Test.stub` injection points — auth_controller tests updated to stub through `Meta.Client`. ✓ resolved
2. **B3 conflict_target change** — existing seeds/test data using email-based upsert will break. New migration `20260421000001` adds unique index on `meta_user_id`. ✓ resolved
3. **P2-T7 telemetry** — using `[:oban, :job, :stop]` with `state: :discarded/:cancelled` and `[:oban, :job, :exception]` against Oban 2.18. ✓ compiles and runs
