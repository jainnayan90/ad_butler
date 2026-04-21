# Iron Law Violations Report

## Summary
- Files scanned: 8 (accounts.ex, user.ex, meta_connection.ex, meta/client.ex, meta/rate_limit_store.ex, workers/token_refresh_worker.ex, controllers/auth_controller.ex, application.ex)
- Iron Laws checked: 15 of 22 (LiveView laws N/A — no LiveView files in this changeset)
- Violations found: 3 (1 critical, 1 high, 1 medium)

---

## Critical Violations

### [#8] String Keys in Oban Args
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex:34`
- **Code**: `%{meta_connection_id: meta_connection_id}`
- **Confidence**: DEFINITE
- **Fix**: `perform/1` correctly matches `%{"meta_connection_id" => id}` (string key), but `schedule_refresh/2` builds the args map with an atom key. Oban JSON-roundtrips all args, so the stored key will be the string `"meta_connection_id"` — but atom-keyed construction is error-prone and violates the Iron Law. Use string keys consistently at the source:
  ```elixir
  %{"meta_connection_id" => meta_connection_id}
  |> new(schedule_in: {days, :days})
  |> Oban.insert()
  ```

---

## High Violations

### [#7] Oban Worker Missing `unique:` Constraint
- **File**: `lib/ad_butler/workers/token_refresh_worker.ex:2`
- **Code**: `use Oban.Worker, queue: :default, max_attempts: 3`
- **Confidence**: REVIEW
- **Fix**: Without `unique:`, a retry race or double call to `schedule_next_refresh/2` could enqueue multiple refresh jobs for the same connection. Add:
  ```elixir
  unique: [period: :infinity, keys: ["meta_connection_id"]]
  ```

---

## Medium Violations

### [Iron Law: Wrap Third-Party APIs] AuthController Calls Req Directly
- **File**: `lib/ad_butler_web/controllers/auth_controller.ex:83,102`
- **Code**: `Req.post(@token_url, ...)` and `Req.get(@user_info_url, ...)`
- **Confidence**: LIKELY
- **Fix**: `AdButler.Meta.Client` already wraps Req behind a `@behaviour`. The auth controller bypasses it with its own raw `Req` calls, splitting Meta HTTP logic and test-stubbing across two modules. Move `exchange_code_for_token/1` and `fetch_user_info/1` into `AdButler.Meta.Client` (e.g., `Client.exchange_code/3`, `Client.get_me/1`).

---

## Specific Questions Addressed

1. **TokenRefreshWorker calls Repo directly?** No — correctly calls `Accounts.get_meta_connection!/1` and `Accounts.update_meta_connection/2` only.
2. **Hardcoded secrets?** None. All `Application.fetch_env!` calls are inside function bodies (runtime). Clean.
3. **AuthController atom keys from user input?** No `String.to_atom` anywhere in lib/. Clean.
4. **Ecto query values pinned?** `accounts.ex:46` uses `^user.id` — correctly pinned. No fragment interpolation found.
5. **Authorization bypass?** AuthController is OAuth-only with no resource mutations. No LiveView files in changeset.
6. **`raw/1` XSS?** No `raw(` calls found anywhere in the changed files.
