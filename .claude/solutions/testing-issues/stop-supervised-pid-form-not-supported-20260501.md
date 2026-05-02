---
title: "stop_supervised!/1 in ExUnit 1.18 only accepts the child id, not a pid"
module: "ExUnit.Callbacks"
date: "2026-05-01"
problem_type: test_helper_misuse
component: exunit
symptoms:
  - "`stop_supervised!(pid)` raises `(RuntimeError) could not stop child ID #PID<...> because it was not found`"
  - "Reviewers/docs sometimes recommend passing the pid for clarity, but it doesn't work in ExUnit 1.18"
---

## Root cause

`ExUnit.Callbacks.stop_supervised!/1` looks up the child by id (atom/module), not by pid. When you pass a pid, it treats `#PID<...>` as a literal child id, fails the lookup, and raises.

The other docs page suggesting `pid_or_id` is for newer ExUnit versions; check `mix deps | grep ex_unit` before relying on it.

## Fix

Use the child id — which is the module name when you start with `start_supervised!({Module, arg})`:

```elixir
# Yes — module is the default child id
pid = start_supervised!({Chat.Server, session_id})
ref = Process.monitor(pid)
stop_supervised!(Chat.Server)
assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

# No — pid form not supported in ExUnit 1.18
stop_supervised!(pid)  # RuntimeError
```

If you need to stop a specific instance when there are multiple, give the child a deliberate id:

```elixir
start_supervised!(
  Supervisor.child_spec({Chat.Server, session_id}, id: {:chat_server, session_id})
)
stop_supervised!({:chat_server, session_id})
```

Alternative: stop directly with `GenServer.stop(pid, :normal, 5000)` or `Process.exit(pid, :shutdown)` and `assert_receive` on the monitor — but that bypasses the supervisor cleanup that `stop_supervised!` performs.
