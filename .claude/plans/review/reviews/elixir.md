## Elixir Code Review — Pass 3

**Status: Changes Requested | 1 Critical · 2 Warnings · 2 Suggestions**

---

## Critical

**1. DigestWorker.perform/1 missing `{:error, reason}` clause**
`lib/ad_butler/workers/digest_worker.ex:18-22`

`deliver_digest/2` is specced as `:ok | {:skip, :no_findings} | {:error, term()}`. The `case` handles only the first two. A Swoosh delivery failure raises `CaseClauseError` instead of returning `{:error, reason}` to Oban.

Fix:
```elixir
case Notifications.deliver_digest(user, period) do
  :ok -> :ok
  {:skip, :no_findings} -> :ok
  {:error, reason} -> {:error, reason}
end
```

---

## Warnings

**2. `DigestMailer.build/4` missing `@spec`**
`lib/ad_butler/notifications/digest_mailer.ex:7`

Has `@doc` but no `@spec`. CLAUDE.md requires `@spec` for every public `def`.

```elixir
@spec build(User.t(), [Finding.t()], String.t(), non_neg_integer() | nil) :: Swoosh.Email.t()
```

**3. SMTP_PORT parsed with bare `String.to_integer/1`**
`config/runtime.exs` (SMTP port line)

Raises a generic `ArgumentError` on bad env value (e.g. trailing space). The project uses `Integer.parse/1` with explicit error message elsewhere (RABBITMQ_POOL_SIZE). Apply consistently.

---

## Suggestions

**4. `deliver_digest/2` uses `if findings == []` instead of function head pattern match**
`lib/ad_butler/notifications.ex:20`

CLAUDE.md: "Pattern-match in function heads, not in case blocks inside the body."

**5. `list_users_with_active_connections/0` loads all users into memory**
`lib/ad_butler/accounts.ex:246-251`

Single `Repo.all/1` holds the full list. Project has `stream_connections_and_run/2` pattern. A streaming variant backed by `Repo.stream/1` avoids heap pressure at scale.
