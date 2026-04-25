# Review: week3-liveview-ui-deploy

**Date**: 2026-04-25  
**Verdict**: REQUIRES CHANGES  
**Summary**: 2 BLOCKERs, 5 WARNINGs, 8 SUGGESTIONs across 4 specialist agents (elixir, security, testing, iron-laws). Auth, tenant isolation, and schema correctness are solid. The critical issues are a crash vector in the telemetry handler and dead reconnect-reload code that gives false confidence.

---

## BLOCKERs

### B1. `Jason.encode!` in telemetry handler can crash the calling process
**File**: `lib/ad_butler/llm/usage_handler.ex:91`  
**Source**: iron-law-judge (DEFINITE)

`encode_metadata/1` calls `Jason.encode!(map)` with a bang. Any non-serializable value in `extra_metadata` (struct, PID, circular ref) raises, propagating out of the telemetry handler and crashing the process that called `:telemetry.execute/3`. Today there's no LLM client, but this is a guaranteed crash vector when one is wired up.

`Repo.insert/2` (no bang) is handled correctly — the only crash path is this `Jason.encode!`.

**Fix**: Replace with `Jason.encode/1` and handle `{:error, _}`:
```elixir
defp encode_metadata(nil), do: nil
defp encode_metadata(map) when is_map(map) do
  case Jason.encode(map) do
    {:ok, json} -> json
    {:error, _} -> nil
  end
end
```

### B2. `handle_info(:reload_on_reconnect)` is dead code — reconnect never refreshes
**File**: `lib/ad_butler_web/live/dashboard_live.ex:20`, `lib/ad_butler_web/live/campaigns_live.ex:174`  
**Source**: elixir-reviewer (BLOCKER), iron-law-judge (SUGGESTION #7)

Both LiveViews implement the reload handler but nothing ever sends `:reload_on_reconnect`. Phoenix LiveView does not automatically dispatch any message on reconnect. There is no `if connected?(socket), do: send(self(), :reload_on_reconnect)` in `mount/3`. Consequence: after a disconnect/reconnect the streams show stale data indefinitely, silently.

This also means data is queried **twice per page load** — once during the disconnected HTTP render and again on WebSocket mount.

**Fix**: In `mount/3`, gate data loading on `connected?(socket)`:
```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    send(self(), :reload_on_reconnect)
  end
  {:ok, socket |> stream(:ad_accounts, []) |> assign(:ad_account_count, 0)}
end
```
Or load data directly in the `connected?` branch without the handler.

---

## WARNINGs

### W1. `UsageHandler.attach()` called before supervisor tree starts
**File**: `lib/ad_butler/application.ex:21`  
**Source**: elixir-reviewer

`UsageHandler.attach()` is called before `Supervisor.start_link/2` (line ~61). If any event fires during the supervisor startup window, `Repo.insert/2` will fail because the Repo process doesn't exist yet. Low risk today (no LLM client), but must be fixed before wiring one up.

**Fix**: Move `UsageHandler.attach()` to after `Supervisor.start_link/2` returns `{:ok, _}`.

### W2. `status` filter param not allowlisted before `push_patch`
**File**: `lib/ad_butler_web/live/campaigns_live.ex:61-68`  
**Source**: iron-law-judge (WARNING), security-analyzer (SUGGESTION)

`params["status"]` is forwarded directly to `push_patch` without an allowlist check. SQL injection is impossible (pinned `^status` binding), but arbitrary strings appear in the URL and persist across navigation. A client can send any string over the WebSocket regardless of the `<select>` options.

**Fix**:
```elixir
@valid_statuses ~w(ACTIVE PAUSED DELETED)
status = if params["status"] in @valid_statuses, do: params["status"]
```

### W3. Flawed duplicate-row assertion in LLM test
**File**: `test/ad_butler/llm/usage_handler_test.exs:63`  
**Source**: testing-reviewer (WARNING W1)

```elixir
count = Repo.aggregate(Usage, :count, :id)
assert count == 1
```

This counts ALL `llm_usage` rows in the sandbox connection. Since `async: false` means prior tests' rows are visible, this will fail when more than one test has inserted a row (the first test's `req-001` row is present when the duplicate test runs). Currently passes only if test ordering happens to be favorable.

**Fix**:
```elixir
import Ecto.Query
count = Repo.aggregate(from(u in Usage, where: u.request_id == "req-dup"), :count, :id)
assert count == 1
```

### W4. Telemetry handler not detached after tests
**File**: `test/ad_butler/llm/usage_handler_test.exs:9-13`  
**Source**: testing-reviewer (WARNING W2)

`UsageHandler.attach()` in `setup` but no `on_exit` teardown. The handler is a global ETS entry that outlives the test module.

**Fix**:
```elixir
on_exit(fn -> :telemetry.detach("llm-usage-logger") end)
```

### W5. `Usage.changeset` — empty `request_id: ""` breaks idempotency via unique index
**File**: `lib/ad_butler/llm/usage.ex:59`  
**Source**: security-analyzer

The non-partial unique index on `request_id` (migration `20260425000002`) allows multiple NULLs but a second insert with `request_id: ""` would conflict with the first on the non-NULL unique key. Two distinct telemetry events with empty string `request_id` would silently dedupe to one row.

**Fix**: In `build_attrs/3`, nilify blank: `request_id: presence(metadata[:request_id])`. Add `validate_length(:request_id, max: 200)` to changeset.

---

## SUGGESTIONs

**S1** — `handle_event("filter")` path untested — only `handle_params` (URL-param) path is exercised. Add `render_change(view, "filter", %{...})` + `assert_patch` test. (`campaigns_live_test.exs`)

**S2** — `[:llm, :request, :exception]` telemetry event not tested — the error-status path (`status: "error"`) has zero test coverage. (`usage_handler_test.exs`)

**S3** — `html =~ "1"` assertion too broad — matches any `1` anywhere on page. Use `html =~ ">1<"` or a more targeted selector. (`dashboard_live_test.exs:25`)

**S4** — `maybe_put` / `maybe_put_str` duplication — two helpers differing only in accumulator type; can be unified with pattern matching on `is_map/is_list`. (`campaigns_live.ex:195-201`)

**S5** — `stat_card` `value` attr typed `:any` — both callers pass integers; typing `:integer` enables compile-time validation. (`dashboard_components.ex:20`)

**S6** — Stale `PHX_SERVER=true` comment in `runtime.exs` — `server: true` is now unconditional in prod; the comment describing the old `PHX_SERVER` guard is misleading. (`config/runtime.exs:10-16`)

**S7** — Duplicate session→user lookup logic in `AuthLive` and `RequireAuthenticated` — drift between them would be a critical auth bug; consider extracting `Accounts.fetch_user_by_session_id/1`.

**S8** — `ad_account_id` filter param: validate as UUID and check against user's owned accounts to prevent UUID probing. Security confirmed no data leaks (scope JOIN protects), but allowlisting is cleaner. (`campaigns_live.ex:37-48`)

---

## What's Correct

- `auth_live.ex`: `assign/3` (not `assign_new/3`) — correct, documented rationale
- Tenant isolation in `CampaignsLive`: `Ads.list_campaigns` JOINs via `meta_connection_id` — confirmed impenetrable by security agent
- `fly.staging.toml`: no secrets, build-secret flags documented in comments
- `LLM.Usage` schema: append-only timestamps, integer cents, `validate_inclusion` for bounded fields
- Migration `20260425000002`: non-partial unique index correctly supports `ON CONFLICT (request_id)`
- `Repo.insert/2` (no bang) in handler: error case handled, only `Jason.encode!` is the crash path
- Defense-in-depth: `:authenticated` plug + `live_session` on_mount both enforce auth
