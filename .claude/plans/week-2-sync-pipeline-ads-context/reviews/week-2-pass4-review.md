# Review: Week 2 — Pass 4 (NW6+NW7+NB3+NW5 fixes)

**Verdict: PASS WITH WARNINGS**
**Date**: 2026-04-22
**Agents**: elixir-reviewer, testing-reviewer
**Scope**: publisher.ex (NW6+NW7), factory.ex (NB3+NW5)

---

## NW6 + NW7 — CONFIRMED CORRECT

NW7 (ref-matched :DOWN clauses): Fully correct. Stale :DOWN when refs are nil correctly falls through to ignore clause. Pathological equal-refs case safe.

NW6 (Connection.close try/catch): Structurally correct but incomplete — see W1.

---

## WARNINGS

### [W1] `catch :exit` does not cover exceptions from `Connection.close/1`
**File**: `lib/ad_butler/messaging/publisher.ex` — do_connect/1 channel failure branch
**Agent**: elixir-reviewer

`:exit` catches exit signals (dead process GenServer call). If `AMQP.Connection.close/1` raises an Elixir exception, it propagates uncaught. In practice AMQP uses GenServer so exit is the dominant path — but not guaranteed.

**Fix**:
```elixir
catch
  :exit, _ -> :ok
  :error, _ -> :ok
end
```

Not a blocker: if uncaught, supervisor restarts GenServer to clean state.

---

### [W2] `ad_set_factory` — `campaign.ad_account` may be `%Ecto.Association.NotLoaded{}` when campaign is persisted
**File**: `test/support/factory.ex` — ad_set_factory
**Agent**: testing-reviewer

`campaign && campaign.ad_account` evaluates to `%Ecto.Association.NotLoaded{}` (truthy) if caller passes a persisted campaign struct without preloaded ad_account. The ad_set would then have `ad_account: %NotLoaded{}`.

**Fix**: Mirror the NW5 guard pattern:
```elixir
ad_account =
  attrs[:ad_account] ||
    case campaign && campaign.ad_account do
      %Ecto.Association.NotLoaded{} -> build(:ad_account)
      nil -> build(:ad_account)
      loaded -> loaded
    end
```

---

### [W3] `ad_factory` — `nil` ad_account not handled
**File**: `test/support/factory.ex` — ad_factory
**Agent**: testing-reviewer

The NW5 `case` covers `%NotLoaded{}` and a catch-all. If `ad_set.ad_account` is `nil` (bare AdSet struct), the catch-all returns `nil`, producing `ad_account: nil` silently.

**Fix**: Add nil clause:
```elixir
case ad_set.ad_account do
  %Ecto.Association.NotLoaded{} -> build(:ad_account)
  nil -> build(:ad_account)
  loaded -> loaded
end
```

---

## Confirmed Non-Issues

- `campaign && campaign.ad_account` nil short-circuit: correct
- Campaign variable rebinding: idiomatic and safe in Elixir
- NW7 stale-ref ignore clause: correct for all cases including pre-connect nil refs
- `:ok` return from try block: correct — result discarded, control flows to Logger.warning + send_after

---

## Pre-existing (not in scope)

- `reconnect/1` calls `do_connect/1` synchronously — mailbox stalls on slow DNS. Noted, deferred.
- plug_attack.ex:23 nesting [F] — pre-existing
