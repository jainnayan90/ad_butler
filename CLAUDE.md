# AdButler — Claude Code Principles

Full rationale for every rule lives in `CODING_PRINCIPLES.md`. This file is the
agent-facing distillation: what to do and what never to do.

---

## Documentation

Every module needs `@moduledoc`. Every public `def` needs `@doc`. Add both in the
same commit as the code — never leave as a follow-up.

- OTP callbacks with `@impl true` are exempt (the behaviour contract documents them).
- Use `@doc false` only for technically-public boilerplate (e.g. Plug `init/1`/`call/2`).
- Test files are exempt.

---

## Testing — TDD

Write the test before the code. Red → Green → Refactor. No untested code in `main`.

- Every context function gets at least one test.
- **Tenant isolation tests are non-negotiable** — for every scoped query, create two
  users, insert data for user A, assert user B's query returns nothing.
- Use `ExUnit.Case, async: true` everywhere possible.
- Use `Mox` for external integrations (Meta API, etc.); never mock what you own.
- Never use `Process.sleep/1` in tests — use `Process.monitor/1` and assert on the
  DOWN message, or `:sys.get_state/1` to synchronise.

---

## Naming and Module Structure

- Names describe what something **is**, not what it does — verbs on functions, nouns on modules.
- Context boundaries are real: `AdButler.Chat` may call `AdButler.Ads.list_ads/1`; it
  may never reach into `AdButler.Ads.Query` or build Ecto queries directly.
- Ecto schemas live inside the context that owns them.
- Web-layer modules are `AdButlerWeb.*`; web concerns must not leak into domain code.

---

## Function Design

- Return `{:ok, value} | {:error, reason}` for anything that can fail. Never raise in
  the happy path.
- Reserve `!` for functions that raise (`get_ad!/1` raises, `get_ad/1` returns a tuple).
- Pattern-match in function heads, not in `case` blocks inside the body.
- Functions do one thing; if the name needs "and", split it.
- Prefer pipelines over nested calls.

---

## Error Handling

- Use `with` for multi-step operations that can fail.
- `rescue` is for wrapping third-party code that raises — never rescue your own code.
- Never swallow errors silently. Every `{:error, reason}` is either propagated or
  logged with enough context to debug. A bare `{:error, _} -> :ok` needs a comment.

---

## Contexts and the Repo Boundary

- `Repo` is only ever called from inside a context module. LiveViews, controllers, and
  other contexts never call `Repo` directly.
- Every user-facing read query passes through `scope/2` (MetaConnection IDs). This is
  the RLS substitute — missing scope = tenant leak = data breach.

---

## Security

- All user-facing queries must pass through a tenant scope (MetaConnection IDs) — one
  user must never access another's data.
- Never expose raw internal IDs in user-facing URLs without ownership checks.
- Validate at system boundaries (user input, external APIs); trust internal code.
- No `String.to_atom/1` on user input.
- No PII (emails, tokens) in URLs, query params, or logs.

---

## Logging and Observability

Always use structured logging — key-value metadata, never string interpolation:

```elixir
# yes
Logger.info("ad paused", ad_id: ad.id, user_id: user.id)

# no
Logger.info("ad #{ad.id} paused for user #{user.id}")
```

Never log secrets, tokens, or PII. Use `AdButler.Log.redact/1` when external API
responses touch a log call.

**Never wrap a metadata field in `inspect/1`.** Pass the raw term — atom, map,
keyword list, `changeset.errors`. The Logger formatter handles serialization
once at the boundary; pre-stringifying via `inspect/1` collapses structure and
defeats log-aggregation filtering. `inspect/1` is for the *message string*, not
the metadata.

```elixir
# yes
Logger.error("audit failed", ad_account_id: id, reason: reason)
Logger.error("finding creation failed", ad_id: id, reason: changeset.errors)

# no
Logger.error("audit failed", ad_account_id: id, reason: inspect(reason))
```

Add every new metadata key to the allowlist in `config/config.exs` Logger
formatter — unallowlisted keys silently drop.

---

## Background Jobs — Oban, Not GenServers

Use **Oban** for all background and scheduled work. Never use GenServers with
`:timer.send_interval` or `Process.send_after` loops for periodic jobs.

GenServers are appropriate only for stateful in-process coordination (connection pools,
rate-limit buckets). If the core job is "do X every Y minutes," that's an Oban worker.

---

## External Services — Behaviours + Mox

Every external service gets a behaviour module first, then a real implementation.
Context modules call the behaviour via `Application.get_env` — never the implementation
directly. Tests configure a Mox mock; prod uses the real client.

Before adding any new third-party service dependency (Sentry, APM, analytics, etc.),
**ask the user first**.

---

## HTTP

Use **`:req` (`Req`)** for all HTTP requests. Never use `:httpoison`, `:tesla`, or `:httpc`.

---

## Secrets and Configuration

- Secrets come from the environment at runtime via `config/runtime.exs`. Never put
  real secrets in `config/config.exs` or `config/prod.exs`.
- Use `System.fetch_env!/1` — fails loudly at boot rather than silently using nil.
- `.env.local` for dev, never committed. Keep `.env.example` up to date — adding an
  env var without updating `.env.example` is a blocker.

---

## Encryption

Use **Cloak** to encrypt PII and tokens at rest (access tokens, OAuth refresh tokens,
emails). Store a SHA-256 hash alongside searchable PII for query lookups; decrypt after
retrieval. Never log the decrypted value.

---

## Migrations

- Migrations are append-only in shared environments — never edit a migration that has
  run in staging or prod.
- Every migration must be reversible (`def change`, or `def up` + `def down`).
- Data backfills go in Oban jobs or `mix` tasks — not in schema migrations.
- Large table changes: add nullable → backfill → add constraint (three migrations).

---

## Performance

- N+1 queries are bugs. Use `Repo.preload/3` or preload in the query; never call `Repo`
  inside an `Enum` loop over a result set.
- Use bulk operations (`Repo.insert_all`, `Repo.update_all`) for anything over ~10 rows.
- Add a database index for every query that runs more than once per request.

---

## Pagination

Every LiveView that renders a list **must use pagination by default**. Never load an
unbounded collection into a stream or assign.

- Use context-level `paginate_*` functions (e.g. `Ads.paginate_campaigns/2`) — they
  return `{items, total_count}`.
- Default `@per_page 50`. Compute `total_pages = max(1, ceil(total / @per_page))`.
- Track `:page` and `:total_pages` as socket assigns; read `:page` from URL params in
  `handle_params/3`. Push patches on filter/page change so the URL stays in sync.
- Render `<.pagination page={@page} total_pages={@total_pages} />` below every table
  (the component hides itself when `total_pages == 1`).

```elixir
{items, total} = MyContext.paginate_things(user, page: page, per_page: @per_page)
total_pages = max(1, ceil(total / @per_page))

socket
|> stream(:things, items, reset: true)
|> assign(:page, page)
|> assign(:total_pages, total_pages)
|> assign(:thing_count, total)
```

---

## LiveView Streams

Always use LiveView streams (`stream/3`, `stream_insert/3`, `stream_delete/3`) for
collections rendered in templates. Never assign a plain list to a socket assign for a
collection rendered in a loop.

---

## LiveView — Disconnected Render Must Not Be Blank

Every LiveView that gates data loading behind `if connected?(socket)` MUST
render a non-empty placeholder on the disconnected branch. The pattern
`<div :if={@finding}>...</div>` alone is a smell — the disconnected first
paint shows an empty body until the websocket upgrades.

```heex
<%!-- yes: placeholder + real content --%>
<div :if={!@finding} class="...">
  <.link navigate={~p"/findings"}>&larr; Back</.link>
  <p class="text-gray-500">Loading…</p>
</div>
<div :if={@finding} class="...">
  ... full page ...
</div>
```

Skeletons (`animate-pulse` shaped divs) are also fine. The fix is NOT to move
the load into `mount/3` — that re-introduces the connection-pool risk
`connected?/1` exists to prevent.

**Test the disconnected branch.** `Phoenix.LiveViewTest.live/2` runs in
connected mode by default and will not catch a blank disconnected render.
Add a plain `Plug.Conn` test:

```elixir
test "disconnected render is non-empty", %{conn: conn} do
  body = conn |> get(~p"/finding/#{id}") |> html_response(200)
  assert body =~ "Loading"
  assert body =~ "Back"
end
```

---

## Styling — No DaisyUI Component Classes

Use **plain Tailwind utility classes only**. DaisyUI component classes are banned.

DaisyUI's theme CSS variable definitions in `assets/css/app.css` are fine to keep.
Only the component classes are banned: `table`, `table-zebra`, `list`, `list-row`,
`btn`, `badge`, `card`, `modal`, `navbar`, `menu`, `tab`, `alert`, `collapse`,
`tooltip`, `progress`, `loading`, `drawer`, etc.

**Why:** The dark DaisyUI theme has `prefersdark: true` and activates when the OS is
in dark mode. Component classes render using CSS variables that shift to near-black
backgrounds, while page containers use hard-coded Tailwind utilities (`bg-white`,
`bg-gray-50`) that don't respond — causing unreadable contrast mismatches.

---

## Pre-commit

Always run `mix precommit` when done with all changes and fix any issues before
considering work complete. This runs formatting, compiler warnings-as-errors, Credo,
and tests in one pass.
