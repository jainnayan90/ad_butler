# Test Review: New Test Files (Week 1, Days 2–5)

## Summary

Five test files and two support files reviewed. Overall structure is solid: async choices are correct, Mox is backed by a behaviour, and Oban testing follows the manual pattern. Several issues exist ranging from a critical encryption assertion bug to missing sad-path coverage.

---

## Issues Found

### Critical

- **accounts_test.exs lines 52–60 — Encryption assertion proves nothing.** `raw_bytes` is loaded through Ecto, which transparently decrypts via `AdButler.Encrypted.Binary` on read. So `raw_bytes == conn.access_token == plaintext` is always true regardless of whether encryption is working. To actually verify ciphertext is stored, bypass Ecto: `Repo.query!("SELECT encode(access_token, 'escape') FROM meta_connections WHERE id = $1", [conn.id])` and assert the result is NOT equal to the plaintext string `"my_secret_token"`.

### Warnings

- **accounts_test.exs line 12 — Hardcoded email `"test@example.com"`.** Will collide if seeds or parallel tests reuse the same scope. Prefer `sequence` or `unique_integer`.

- **accounts_test.exs lines 27–30 — Inline `Repo.aggregate` query in test body.** Tightly couples test to schema internals. The upsert returning `{:ok, updated}` with matching id is sufficient.

- **token_refresh_worker_test.exs line 31 — `assert_enqueued` does not pin args.** Passes even if the enqueued job has the wrong `meta_connection_id`. Add `args: %{"meta_connection_id" => conn.id}`.

- **token_refresh_worker_test.exs — `async: true` with `Mox.expect` requires `set_mox_from_context`.** Add `setup :set_mox_from_context` to the worker test module to be explicit and avoid race conditions.

- **factory.ex line 16 — `:meta_user_id` sequence name shared between `user_factory` and `meta_connection_factory`.** Use a distinct name (e.g., `:mc_meta_user_id`) in the connection factory.

- **factory.ex line 19 — `access_token` uses `System.unique_integer` instead of `sequence/2`.** `System.unique_integer` is evaluated once at module load; use `sequence(:access_token, &"token_#{&1}")` for proper per-build evaluation.

- **meta/client_test.exs line 43 — ETS row not cleaned up in `on_exit`.** The inserted `"act_999"` row persists across tests. Add `on_exit(fn -> :ets.delete(@rate_limit_table, "act_999") end)`.

### Suggestions

- **accounts_test.exs — Missing: duplicate `(user_id, meta_user_id)` constraint error path.** The schema has `unique_constraint([:user_id, :meta_user_id])` with no test covering it.

- **accounts_test.exs — Missing: `update_meta_connection/2` invalid attrs returns error changeset.**

- **token_refresh_worker_test.exs — Missing: `meta_connection_id` references non-existent record.**

- **auth_controller_test.exs — Missing: token exchange HTTP failure (4xx/5xx from Meta API).**

- **meta/client_test.exs — No tests for `list_campaigns`, `list_ad_sets`, `list_ads`, `get_creative`.**
