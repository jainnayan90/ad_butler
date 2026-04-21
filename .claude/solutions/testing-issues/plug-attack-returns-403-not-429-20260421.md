---
module: "AdButlerWeb.PlugAttack"
date: "2026-04-21"
problem_type: test_failure
component: testing
symptoms:
  - "Test asserts conn.status == 429 but actual status is 403"
  - "Rate limiting is working but test fails with unexpected status code"
root_cause: "PlugAttack default block response is HTTP 403 Forbidden, not 429 Too Many Requests"
severity: low
tags: [plug-attack, rate-limiting, 403, 429, http-status, test-assertion]
---

# PlugAttack Returns 403, Not 429

## Symptoms

Test for rate limiting asserts HTTP 429 (Too Many Requests):

```elixir
assert conn.status == 429  # FAILS
```

Actual response is 403 Forbidden.

## Root Cause

PlugAttack's default `allow/block` response sends **HTTP 403**, not 429. The 429 status code is semantically more correct for rate limiting, but PlugAttack's out-of-the-box behavior uses 403.

To return 429 you must override the `block_action/3` callback:

```elixir
# Default behavior (403)
use PlugAttack

# Override to return 429
def block_action(conn, _data, _opts) do
  conn
  |> Plug.Conn.put_resp_content_type("text/plain")
  |> Plug.Conn.send_resp(429, "Too Many Requests")
  |> Plug.Conn.halt()
end
```

## Solution

Either:

**A) Update the test to assert 403** (matches default behavior):

```elixir
assert conn.status == 403
```

**B) Override `block_action/3` in `AdButlerWeb.PlugAttack`** to return 429 and keep the test as-is.

Current project uses option A (assert 403).

### Files Changed

- `test/ad_butler_web/plugs/plug_attack_test.exs` — changed assertion to `assert conn.status == 403`

## Prevention

- [ ] When adding PlugAttack tests: assert 403, not 429, unless `block_action/3` is overridden
- [ ] Document the 403 behavior in `AdButlerWeb.PlugAttack` if the team expects 429

## Related

- `lib/ad_butler_web/plugs/plug_attack.ex` — current PlugAttack config (no block_action override)
