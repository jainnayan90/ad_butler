# Review: Week 2 — Final Pass (Round 3)

**Verdict: REQUIRES CHANGES**
**Date**: 2026-04-22
**Agents**: elixir-reviewer, oban-specialist, testing-reviewer
**Scope**: Final state of publisher.ex, fetch_ad_accounts_worker.ex, factory.ex, worker test

---

## BLOCKERS

### [NB3] `ad_set_factory` — `campaign:` override ignores campaign's ad_account
**File**: `test/support/factory.ex:51-52`
**Agent**: testing-reviewer

When a caller passes `campaign: existing_campaign` but omits `ad_account:`, the current factory:
```elixir
ad_account = attrs[:ad_account] || build(:ad_account)   # NEW unrelated ad_account
campaign   = attrs[:campaign]                            # caller's campaign, tied to a DIFFERENT ad_account
```
The AdSet ends up with `ad_account` and `campaign` owned by two different ad_accounts.
Any `insert(:ad_set, campaign: c)` call will either FK-fail or silently produce an inconsistent graph.

**Fix**:
```elixir
def ad_set_factory(attrs) do
  campaign   = attrs[:campaign]
  ad_account = attrs[:ad_account] || (campaign && campaign.ad_account) || build(:ad_account)
  campaign   = campaign || build(:campaign, ad_account: ad_account)
  ...
end
```

---

## WARNINGS

### [NW5] `ad_factory` — `ad_set.ad_account` may be `%Ecto.Association.NotLoaded{}`
**File**: `test/support/factory.ex:69`
**Agent**: testing-reviewer

```elixir
ad_account = attrs[:ad_account] || ad_set.ad_account
```
When a test passes a persisted `%AdSet{}` struct (from `insert(:ad_set)`), Ecto does not preload associations. `ad_set.ad_account` is `%Ecto.Association.NotLoaded{}` and gets assigned silently as the ad_account association.

**Fix**:
```elixir
ad_account =
  attrs[:ad_account] ||
    case ad_set.ad_account do
      %Ecto.Association.NotLoaded{} -> build(:ad_account)
      loaded -> loaded
    end
```

### [NW6] `AMQP.Connection.close/1` can raise on dead pid
**File**: `lib/ad_butler/messaging/publisher.ex:67`
**Agent**: elixir-reviewer

`AMQP.Connection.close(conn)` calls `:amqp_connection.close(conn.pid)` with no rescue. If the pid is already dead, the GenServer crashes with `{:noproc, ...}`. Channel-open failures sometimes leave the connection in an inconsistent state.

**Fix**:
```elixir
try do
  AMQP.Connection.close(conn)
catch
  :exit, _ -> :ok
end
```

### [NW7] Stale `:DOWN` after reconnect triggers spurious teardown
**File**: `lib/ad_butler/messaging/publisher.ex:48`
**Agent**: elixir-reviewer

`handle_info({:DOWN, _ref, :process, _pid, reason}, state)` wildcards `_ref`. A `:DOWN` for the old connection queued in the mailbox before `:connect` finished fires on the healthy new state, tearing it down again.

**Fix** — match ref against state:
```elixir
def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
  Logger.warning("AMQP connection down", reason: inspect(reason))
  {:noreply, reconnect(state)}
end
def handle_info({:DOWN, ref, :process, _pid, reason}, %{channel_ref: ref} = state) do
  Logger.warning("AMQP channel down", reason: inspect(reason))
  {:noreply, reconnect(state)}
end
def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
```

---

## SUGGESTIONS

| # | File | Finding |
|---|------|---------|
| S1 | `publisher.ex` | `@exchange` hardcoded in both publisher.ex and rabbitmq_topology.ex — typo drift causes silent publish failures; extract to shared config |
| S2 | `worker.ex` | No `timeout/1` callback — Meta API + N publishes can hold executor slot indefinitely; add `def timeout(_job), do: :timer.minutes(2)` |
| S3 | `worker.ex` | Partial failure visibility — telemetry event with success/error counts per run would help observability |

---

## Confirmed Clean

- B1–B5 fixes: all verified correct
- NW1–NW4 fixes: all verified correct
- `Jason.encode/1` with-clause match `{:ok, payload}` — confirmed correct
- `run_sync/2` as private function — idiomatic, no credo issue
- Missing-connection test — correct and complete
- `mix precommit` + `mix credo --strict`: 0 new warnings, only pre-existing [F]/[D]
