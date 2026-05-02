---
module: "AdButlerWeb.ChatLive.Show test pattern"
date: "2026-05-02"
problem_type: testing_pattern
component: liveview
symptoms:
  - "A LiveView test for `start_async` error branches asserts on the flash but the assertion fails because the form's render_submit returns BEFORE the Task resolves"
  - "Tests using Mox with set_mox_global to mock a process that runs under DynamicSupervisor (not the test pid) need async: false"
  - "Tests for {:ok, {:error, _}} async branch can't easily use Mox alone because some error paths are gated by Chat.Server's :reply, :ok pattern — the GenServer eats the error and replies :ok"
root_cause: "`start_async/3` spawns a Task whose result is delivered as a process message; `render_submit` returns immediately after the form change, but `handle_async/3` runs only when the Task message is processed. `render(view)` reads the LiveView's *current* assigns — which haven't been updated yet. The fix is `render_async(view, timeout)`, which blocks until pending async results have been processed, OR `assert_receive` on a known PubSub side effect. Additionally, when a GenServer always replies :ok regardless of internal failures (broadcasting errors via PubSub instead), tests for the {:ok, {:error, _}} async branch can't be triggered by mocking the GenServer's collaborators — the error has to be triggered upstream of the GenServer call."
severity: medium
tags: [liveview, testing, start_async, mox, genserver, render_async, ad-butler]
---

# Testing LiveView `handle_async` error branches needs `render_async`

## Symptoms

The LiveView under test:

```elixir
def handle_event("send_message", %{"body" => body}, socket) do
  case String.trim(body) do
    "" -> {:noreply, socket}
    trimmed ->
      socket =
        socket
        |> assign(:sending, true)
        |> start_async(:send_turn, fn ->
          Chat.send_message(user_id, session_id, trimmed)
        end)
      {:noreply, socket}
  end
end

def handle_async(:send_turn, {:ok, {:error, _reason}}, socket) do
  {:noreply, socket |> assign(:sending, false) |> put_flash(:error, "Send failed")}
end

def handle_async(:send_turn, {:exit, _reason}, socket) do
  {:noreply, socket |> assign(:sending, false) |> put_flash(:error, "Agent crashed")}
end
```

A naive test:

```elixir
_ = view |> form("form", %{"body" => "hello"}) |> render_submit()
assert render(view) =~ "Send failed"  # FAILS — html shows "Sending…" still
```

The `render(view)` returns BEFORE the `start_async` Task has resolved.
The flash hasn't been put yet.

## Root Cause

`start_async/3` spawns a Task and returns immediately. `render_submit`
also returns immediately after `handle_event` finishes. The Task's
result is delivered as a `{ref, result}` message to the LiveView,
which `handle_async/3` consumes. Until that message is processed,
the LiveView's assigns reflect the pre-Task state.

`render(view)` synchronously reads the current connected-mode assigns;
it does NOT block until pending async work resolves.

## Fix

Use `render_async/2` from `Phoenix.LiveViewTest`:

```elixir
_ = view |> form("form", %{"body" => "hello"}) |> render_submit()

# Block until pending start_async results have been processed.
html = render_async(view, 1_000)

assert html =~ "Send failed"
refute html =~ "Sending…"
```

`render_async` waits up to `timeout` for `handle_async/3` callbacks
to complete, then re-renders.

## Triggering the {:ok, {:error, _}} branch when the GenServer eats errors

Concrete situation: `Chat.send_message/3` calls `Chat.Server.send_user_message/2`
which is a `GenServer.call`. Inside the GenServer, when the LLM stream
fails, the server *broadcasts* a `{:turn_error, ...}` PubSub message
and replies `{:reply, :ok, state}`. So `Chat.send_message` returns
`:ok`, not `{:error, _}` — and `handle_async` fires the success
clause, not the error clause.

Mocking the LLM client to return `{:error, _}` therefore does NOT
exercise the LiveView's `{:ok, {:error, _}}` branch.

To trigger it, find a path *upstream* of the GenServer call that
returns `{:error, _}`. In this codebase, `Chat.send_message/3`'s
`with` chain calls `Chat.ensure_server/2` first, which calls
`Chat.get_session/2` for re-validation. Deleting the session row
between the LiveView mount and the form submit causes
`get_session/2` to return `{:error, :not_found}`, and
`Chat.send_message/3` short-circuits with `{:error, :not_found}`:

```elixir
test "handle_async {:ok, {:error, _}} flashes 'Send failed'", %{conn: conn} do
  user = insert(:user)
  {:ok, session} = Chat.create_session(%{user_id: user.id})
  conn = log_in_user(conn, user)
  {:ok, view, _html} = live(conn, ~p"/chat/#{session.id}")
  _ = render(view)

  Repo.delete!(session)  # auth path will fail on next send

  _ = view |> form("form", %{"body" => "hello"}) |> render_submit()
  html = render_async(view, 500)

  assert html =~ "Send failed"
end
```

No Mox needed. Async-friendly. The test stays in `async: true`.

## Triggering the {:exit, _} branch via Mox

For the `{:exit, _}` branch, mock the LLM client to *raise* during
`stream/2`. Because the Chat.Server runs under a DynamicSupervisor
(not linked to the test pid), `set_mox_from_context` won't route
the calls — use `set_mox_global` and `async: false`:

```elixir
defmodule MyTest do
  use AdButlerWeb.ConnCase, async: false   # because set_mox_global
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  test "handle_async {:exit, _} flashes 'Agent crashed'", %{conn: conn} do
    expect(LLMClientMock, :stream, fn _, _ -> raise "boom" end)
    stub(LLMClientMock, :stop, fn _ -> :ok end)

    # ... mount ...
    _ = view |> form("form", %{"body" => "hi"}) |> render_submit()
    html = render_async(view, 1_000)

    assert html =~ "Agent crashed"
  end
end
```

The raise propagates: `LLMClient.stream/2` raises → `Chat.Server.run_turn/2`
crashes (no `catch :exit, _` in the call path) → `GenServer.call`
exits in the spawned Task → `start_async` Task exits → `handle_async`
fires the `{:exit, _}` clause.

## Why split into two test files

- show_test.exs stays `async: true` (uses session-deletion trick).
- show_async_error_test.exs goes `async: false` with Mox global.

Mixing `set_mox_global` into an `async: true` file is unsound —
global mode forces serial Mox dispatch and races with parallel
test cases.

## Related

- Phoenix.LiveViewTest.render_async/2 docs
- AdButler.Chat.Server `{:reply, :ok, state}` pattern in
  `handle_call({:send_user_message, _}, _, _)` — see lib/ad_butler/chat/server.ex
- `.claude/solutions/testing-issues/mox-stub-vs-expect-async-strategy-20260421.md`
- Chat.Server's PubSub error broadcasting — broadcast-and-reply-:ok
  is intentional (the Server's caller doesn't care about LLM-side
  failures; the LiveView listens on PubSub for user-visible signals)
