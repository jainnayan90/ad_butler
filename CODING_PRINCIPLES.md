# AdButler — Coding Principles

A living document. These are the rules we agree to follow when writing code for AdButler. They're opinionated on purpose — a shared set of defaults is cheaper than rehashing style every PR.

**How to use this doc.** Read it, challenge it, edit it. Add principles you care about. Delete ones that feel wrong for how you work. The version you commit is the contract; anything not in here is fair game for per-PR discussion.

The principles are grouped. Each has a short rule, a one-paragraph rationale, and (where useful) a small example.

---

## 1. Test-Driven Development (TDD)

**Write the test before the code.** Not after, not "when there's time." The test defines what success looks like — write it first, watch it fail, then make it pass.

**Red → Green → Refactor.** Start with a failing test (red), write just enough code to pass (green), then clean up (refactor). Each cycle is small: minutes, not hours. If you're in a 2-hour red phase, the test is too big — split it.

**TDD is design pressure.** If the test is hard to write, the API is probably wrong. An untestable function is usually doing too much, hiding dependencies, or leaning on global state. Let the test tell you when to split, inject, or simplify.

**The first test for a feature defines the interface.** Before touching implementation, write the test that calls the public API you wish existed. This forces you to think from the caller's perspective: What data goes in? What comes back? What can go wrong?

```elixir
# Start here — the test you wish worked
test "pauses an active ad", %{user: user, ad: ad} do
  assert {:ok, paused_ad} = Ads.pause_ad(ad.id, user)
  assert paused_ad.status == :paused
end

# Now make Ads.pause_ad/2 exist and pass
```

**Skipping TDD for "quick fixes" is how bugs ship.** The pressure to skip the test is highest exactly when the change is risky (tight deadline, unclear requirements, touching old code). That's when the test matters most. No untested code in `main`, no exceptions.

**Tests are executable documentation.** Six months from now, the test suite is the most honest description of what the system does. Write tests that future-you can read and immediately understand the contract.

---

## 2. Naming and module structure

**Names describe what something *is*, not what it *does*.** A module named `BudgetLeakAuditor` is clearer than `AnalyzeBudgetLeaks`. Verbs belong on functions, not modules.

**Context boundaries are real boundaries.** Code in `AdButler.Chat` may call `AdButler.Ads.list_ads/1` — it may not reach into `AdButler.Ads.Query` or build Ecto queries directly. If a context needs something its public API doesn't expose, the right move is to extend the API, not bypass it.

**Ecto schemas live inside the context that owns them.** `AdButler.Ads.Ad`, `AdButler.Meta.Connection`. A schema shared across contexts is a smell — the shared thing probably wants its own context.

**Web layer modules are `AdButlerWeb.*`.** Phoenix's default. Don't let web concerns leak into the domain code; a LiveView calls context functions and renders.

---

## 3. No GenServers for Periodic or Background Work

**Use Oban for background jobs and scheduled work.** Not GenServers with `:timer.send_interval`, not Task.async supervised loops, not homebrew schedulers. Oban gives you persistence, retries, observability, and backpressure for free.

**GenServers are for stateful coordination, not cron jobs.** A GenServer holding a WebSocket connection or managing a rate-limit token bucket = good use. A GenServer that wakes up every 5 minutes to fetch ads from Meta = wrong tool. The latter is an Oban worker with `schedule: "*/5 * * * *"`.

**Scheduled work belongs in `Oban.Worker` modules.** Each recurring task (sync Meta ads, analyze budget leaks, rotate stale tokens) is a worker. The schedule lives in config or the database (via `Oban.insert_all` with scheduled times), not scattered across supervision trees.

```elixir
# Yes — Oban worker for periodic sync
defmodule AdButler.Workers.SyncMetaAds do
  use Oban.Worker, queue: :sync, max_attempts: 3

  @impl Oban.Worker
  def perform(%{args: %{"user_id" => user_id}}) do
    user = Accounts.get_user!(user_id)
    Meta.sync_ads_for_user(user)
  end
end

# Schedule in config/runtime.exs
config :adbutler, Oban,
  plugins: [
    {Oban.Plugins.Cron, 
      crontab: [
        {"*/15 * * * *", AdButler.Workers.SyncMetaAds},
        {"0 2 * * *", AdButler.Workers.AnalyzeBudgetLeaks}
      ]
    }
  ]

# No — GenServer with timer (don't do this)
defmodule AdButler.MetaSyncer do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, [])

  def init(_) do
    schedule_sync()
    {:ok, %{}}
  end

  def handle_info(:sync, state) do
    # sync logic here — now you've reinvented Oban badly
    schedule_sync()
    {:noreply, state}
  end

  defp schedule_sync, do: Process.send_after(self(), :sync, :timer.minutes(15))
end
```

**Jobs that fail get retried automatically.** Oban handles exponential backoff, dead-letter queues, and max attempts. You write the business logic; Oban handles the failure modes.

**Observability is built-in.** Oban emits telemetry events, tracks job state in Postgres, and integrates with Oban Web (or roll your own LiveView dashboard). A GenServer timer gives you nothing unless you instrument it yourself.

**Exceptions: GenServers are fine for...** Connection pools, caches with TTL + LRU eviction, local coordinators (like Phoenix.PubSub's registry). Anything that's truly stateful and lives in-process. But if the core job is "do X every Y minutes," that's Oban.

---

## 4. Function design

**Return `{:ok, value} | {:error, reason}` for anything that can fail.** No raising in the happy path. Raise only for programmer errors (invariant violations), never for user errors or external failures.

**Reserve `!` for functions that raise.** `get_ad!/1` raises if not found; `get_ad/1` returns `{:ok, ad} | {:error, :not_found}`. Pick one convention per function; never do both.

**Pattern-match in function heads, not in `case` blocks.** Small functions, clear clauses.

```elixir
# yes
def pause_ad(%{status: :active} = ad, context), do: ...
def pause_ad(%{status: :paused}, _context), do: {:error, :already_paused}

# no
def pause_ad(ad, context) do
  case ad.status do
    :active -> ...
    :paused -> {:error, :already_paused}
  end
end
```

**Functions do one thing.** If a function's name needs "and" to describe it, split it.

**Prefer pipelines over nested calls.** Read top-to-bottom, not inside-out.

---

## 5. Error handling

**Use `with` for multi-step operations that can fail.** Flatten the error paths.

```elixir
with {:ok, conn} <- Accounts.meta_connection_for(user),
     {:ok, token} <- Meta.ensure_fresh_token(conn),
     {:ok, ads}  <- Meta.Client.list_ads(token, ad_account) do
  Ads.upsert_many(user, ads)
end
```

**`rescue` is for integrations with code that raises (often libraries).** Wrap the raising call, convert to a tagged tuple, move on. Don't `rescue` your own code — fix the code.

**Exit reasons matter.** When a process crashes, it crashes. Let supervisors restart it. Catching and logging a process exit "to be safe" usually hides the real bug.

**Never swallow errors silently.** Every `{:error, reason}` either gets propagated up the call chain or logged with enough context to debug. A bare `case ... do {:error, _} -> :ok end` is a code smell; make the intent explicit (`# safe to ignore: token already rotated`) or don't do it.

---

## 6. Contexts and the Repo boundary

**`Repo` is only ever called from inside a context module.** LiveViews don't call `Repo`. Controllers don't call `Repo`. Other contexts don't call another context's `Repo`.

**Every read query inside a tenant-scoped context passes through `scope/2`.** This is the RLS-substitute (see `decisions/0001-skip-rls-for-mvp.md`). No exceptions; missing scope = tenant leak = data breach.

```elixir
# in Ads context
def list_ads(%User{} = user, opts \\ []) do
  Ad
  |> scope(user)
  |> filter(opts)
  |> Repo.all()
end

defp scope(query, %User{id: user_id}) do
  from q in query,
    join: aa in assoc(q, :ad_account),
    join: mc in assoc(aa, :meta_connection),
    where: mc.user_id == ^user_id
end
```

**One level of abstraction per function.** The public `list_ads/2` orchestrates; the private helpers compose the query. Don't mix both in one function.

---

## 7. Testing

**Every context function gets at least one test.** Write it when you write the function, not later.

**Tenant isolation tests are non-negotiable.** Every query function that reads tenant-scoped data has a test that creates two users, inserts data for user A, asserts user B's query returns nothing. This is how we prevent the worst bug.

**Prefer `ExUnit.Case, async: true` everywhere.** Slow synchronous tests accumulate. If a test can't be async, document why at the top.

**Use `Mox` for external integrations.** Real HTTP calls in tests = flaky tests. Define a behaviour (`Meta.ClientBehaviour`) and a Mox mock. Tests use the mock; prod uses the real client. `Req` has good built-in testing helpers too — either is fine, pick one per integration and stay consistent.

**Don't mock what you own.** Your own context modules get tested with real DB, real state. Only mock things at the edge of the system (HTTP, time, randomness).

**Freeze time with `DateTime.utc_now/0` overridable via `Application.get_env`.** Or use a small `AdButler.Clock` module. Tests that depend on time should never use the real wall clock.

**Property-based tests for heuristics.** The budget leak and creative fatigue analyzers are the right place for StreamData. Fuzz the inputs; assert invariants (e.g., "leak score is always 0 ≤ n ≤ 100", "fatigue score is monotonic in frequency given everything else fixed").

---

## 8. Logging and observability

**Structured logging, always.** Every log call has key-value metadata, not string interpolation.

```elixir
# yes
Logger.info("ad paused", ad_id: ad.id, user_id: user.id, reason: reason)

# no  
Logger.info("ad #{ad.id} paused for user #{user.id} because #{reason}")
```

**Never log secrets.** No access tokens, no API keys, no user passwords (we don't have these but still), no PII beyond what's necessary for a support ticket. Redaction helpers in `AdButler.Log` for the ambiguous cases.

**Every external call has a telemetry event.** `[:adbutler, :meta, :request]`, `[:adbutler, :openai, :embedding]`, etc. Measurements = quantitative data, metadata = identifiers. One event per call, emitted from the client layer, not the caller.

**Every Broadway stage and Oban job emits telemetry.** Free for Broadway, need to add to Oban via `Oban.Telemetry`.

**Logs are for humans; telemetry is for machines.** Don't conflate them. A `Logger.info` that fires 1,000 times/minute is a broken log. A `:telemetry.execute` that fires 1,000 times/minute is fine — aggregators handle it.

---

## 9. External Services — Behaviours + Mox

**Every external service gets a behaviour.** Meta API, OpenAI, any future integrations — define a behaviour (Elixir interface) first, implement the real client second. This makes the boundary explicit and testing trivial.

```elixir
defmodule AdButler.Meta.ClientBehaviour do
  @callback list_ads(token :: String.t(), account_id :: String.t()) ::
    {:ok, list(map())} | {:error, term()}
  
  @callback pause_ad(token :: String.t(), ad_id :: String.t()) ::
    {:ok, map()} | {:error, term()}
end
```

**The real implementation lives in a dedicated module.** `AdButler.Meta.Client.HTTP` implements `Meta.ClientBehaviour` and makes actual HTTP requests via `Req`. Production config points here.

```elixir
defmodule AdButler.Meta.Client.HTTP do
  @behaviour AdButler.Meta.ClientBehaviour

  @impl true
  def list_ads(token, account_id) do
    Req.get("https://graph.facebook.com/v18.0/#{account_id}/ads",
      auth: {:bearer, token}
    )
    |> handle_response()
  end

  # ... more implementations
end
```

**Tests use Mox to mock the behaviour.** Define a mock in `test/support/mocks.ex`, configure it in `test_helper.exs`, stub it in tests. No real HTTP calls, no flaky tests, no waiting on external APIs.

```elixir
# test/support/mocks.ex
Mox.defmock(AdButler.Meta.ClientMock, for: AdButler.Meta.ClientBehaviour)

# In a test
test "pauses ad via Meta API", %{user: user, ad: ad} do
  Meta.ClientMock
  |> expect(:pause_ad, fn _token, ad_id ->
    assert ad_id == ad.meta_id
    {:ok, %{"status" => "PAUSED"}}
  end)

  assert {:ok, paused} = Ads.pause_ad(ad.id, user)
  assert paused.status == :paused
end
```

**Context modules call the behaviour, not the implementation.** Use `Application.get_env` or a module attribute to determine which client to use. Tests configure the mock; prod uses the real client.

```elixir
defmodule AdButler.Meta do
  @client Application.compile_env(:adbutler, :meta_client, AdButler.Meta.Client.HTTP)

  def sync_ads_for_user(user) do
    with {:ok, token} <- ensure_fresh_token(user),
         {:ok, ads} <- @client.list_ads(token, user.ad_account_id) do
      # process ads
    end
  end
end

# config/test.exs
config :adbutler, meta_client: AdButler.Meta.ClientMock

# config/runtime.exs (prod/dev)
config :adbutler, meta_client: AdButler.Meta.Client.HTTP
```

**One behaviour per external service.** Don't make a giant `ExternalAPIBehaviour` that talks to Meta, OpenAI, and Stripe. Each service gets its own behaviour, its own client, its own mock. Boundaries stay clean.

**Req is the HTTP client.** It's in the stdlib, well-maintained, and has excellent testing support. If you need something Req doesn't do, question whether you really need it before adding another HTTP library.

**Real integration tests in CI are optional, but document how to run them.** A `mix test.integration` task that hits real APIs (with test credentials) catches issues Mox can't. Run it manually or in a separate CI job, not on every PR. Keep it fast by limiting scope.

**Behaviours document the contract.** Every function has a `@callback` with a typespec. The behaviour is the source of truth for what the external service provides. If the API changes, the behaviour changes first, then implementations update.

---

## 10. Secrets and configuration

**Secrets come from the environment at runtime, never from compiled config.** `config/runtime.exs` for anything sensitive. Never use `config/config.exs` or `config/prod.exs` for real secrets.

**Every config key has a sensible default or fails loudly at boot.** No silent fallbacks for required values.

```elixir
# runtime.exs
cloak_key = System.fetch_env!("CLOAK_KEY")  # raises with a clear message if missing
```

**Secrets rotation is a planned operation.** Every secret (Cloak key, Meta app secret, LLM API keys) has a rotation runbook in `docs/runbooks/`. Don't wait for the incident.

**`.env.local` for dev, never committed.** `.env.example` committed, kept up to date — adding a new env var without updating `.env.example` is a PR blocker.

---

## 11. Encryption — Cloak for PII, Never Log Secrets

**Use Cloak to encrypt sensitive data at rest.** Access tokens, API keys, OAuth refresh tokens, any PII (email addresses, names if you store them) — encrypt before writing to the database. Cloak integrates with Ecto and handles key rotation.

```elixir
defmodule AdButler.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, AdButler.Encrypted.Binary  # Cloak field
    field :email_hash, :binary  # For lookups
    # ...
  end
end

# Query by hash, decrypt after retrieval
def get_user_by_email(email) do
  email_hash = :crypto.hash(:sha256, email)
  Repo.get_by(User, email_hash: email_hash)
end
```

**Hash + encrypt for searchable PII.** Emails need to be looked up, but you don't want plaintext in the database. Store both: `email` (encrypted via Cloak) for display, `email_hash` (SHA-256) for queries. Same pattern for phone numbers, etc.

**Never log secrets, tokens, or PII.** This bears repeating even though it's in section 8. No access tokens in logs. No API keys. No user emails unless absolutely necessary for a support ticket (and then redact in prod logs). No passwords, ever.

```elixir
# NO — logs the token
Logger.info("Syncing ads", token: token, user_id: user.id)

# YES — logs only identifiers
Logger.info("Syncing ads", user_id: user.id, token_prefix: String.slice(token, 0..7))

# BETTER — use telemetry, don't log tokens at all
:telemetry.execute([:adbutler, :meta, :sync], %{duration: duration}, %{user_id: user.id})
```

**Redaction helpers for ambiguous cases.** Build `AdButler.Log.redact/1` that takes a map and strips known secret keys (`access_token`, `refresh_token`, `password`, `secret`, etc.) before logging. Use it everywhere logs might touch external data.

```elixir
defmodule AdButler.Log do
  @secret_keys ~w(password access_token refresh_token secret api_key token)

  def redact(data) when is_map(data) do
    Map.new(data, fn {k, v} ->
      if to_string(k) in @secret_keys do
        {k, "[REDACTED]"}
      else
        {k, v}
      end
    end)
  end
end

# Usage
Logger.debug("Meta API response", response: Log.redact(response_body))
```

**Cloak key rotation is a runbook.** The CLOAK_KEY env var encrypts everything. Rotating it requires re-encrypting all data. Document the process in `docs/runbooks/rotate-cloak-key.md` before you need it. Test the runbook in staging.

**Database backups contain encrypted data.** This is good — a stolen backup doesn't leak tokens or PII. But it also means you need the Cloak key to restore. Store the key separately from backups (e.g., in your secret manager, not in the backup itself).

**Encryption isn't magic.** It protects data at rest and in backups. It doesn't protect against SQL injection (you still validate inputs), application-level leaks (logs, error messages), or someone with database access who also has the Cloak key. Defense in depth.

**No PII in URLs, query params, or analytics.** User IDs are fine (they're opaque). User emails, names, tokens = never in a URL. URLs get logged everywhere (proxies, browsers, analytics). Use POST bodies or encrypted session data.

**Audit logging is separate from encryption.** `actions_log` (see section 14) stores who-did-what. That's not encrypted — it's how you investigate incidents. But it logs user IDs and action types, not the decrypted PII or the tokens used.

---

## 12. Dependencies

**Adding a dependency is a decision, not a reflex.** Before `mix.exs` grows a line, answer: what does this do that I can't do in 30 lines? Who maintains it? Is it on a major version? When was it last updated?

**Prefer stdlib, Ecto, Phoenix, and Req.** These are the core we're already committed to. Adding a fifth pillar needs to clear a bar.

**No dependency that pulls in a C compiler unless unavoidable.** Pin versions with `==` for critical deps, `~>` for the rest.

**Delete unused deps.** `mix deps.clean --unused` is a normal part of refactoring.

---

## 13. Migrations and data changes

**Migrations are append-only in shared environments.** Never edit a migration that has run in staging or prod. Write a new migration that fixes the schema.

**Every migration is reversible.** `def change` is fine for simple cases; otherwise `def up` + `def down`. Reversibility forces you to think about what rollback looks like.

**Data migrations are separate from schema migrations.** Schema changes go in `priv/repo/migrations/`. Data backfills go in Oban jobs or one-off `mix` tasks in `lib/mix/tasks/`, documented in the PR, versioned in git.

**Big migrations are broken up.** Adding a column with a default on a huge table = multi-statement migration. Add nullable → backfill → add constraint.

---

## 14. Git discipline

**One logical change per commit.** A commit that mixes refactor + feature is a commit that can't be reverted cleanly.

**Commit messages follow Conventional Commits casually.** `feat(ads): add scope helper`, `fix(meta): handle rate-limit headers`, `chore: bump phoenix to 1.7.14`. Don't be religious; do be consistent.

**Branch names are scoped.** `feat/meta-oauth-flow`, `fix/rate-limit-ledger`, `chore/bump-deps`. No `nj/work-in-progress`.

**Main is always deployable.** If `main` is broken, everyone stops and fixes it. No "we'll fix it after lunch."

**PRs exist even for solo work.** Small PRs force you to think about the change as a unit. GitHub's PR description is the best place to write down the why.

---

## 15. Code Quality Gates — Formatting, Credo, Compiler, Tests, Coverage

**Run `mix precommit` before every push.** This single command runs all quality gates locally: formatter check, Credo, compiler warnings as errors, tests, and coverage. If it fails locally, it will fail in CI. Fix it before pushing.

```bash
# mix.exs or mix/tasks/precommit.ex
defp aliases do
  [
    precommit: [
      "format --check-formatted",
      "compile --warnings-as-errors",
      "credo --strict",
      "test --cover",
      "coveralls.html"
    ]
  ]
end
```

**`mix format` is non-negotiable.** All code is formatted with `mix format` before commit. No exceptions, no style debates. The formatter wins every argument. Run `mix format --check-formatted` in CI to enforce.

**Compiler warnings are errors in CI.** `mix compile --warnings-as-errors` catches unused variables, missing typespecs on callbacks, ambiguous code. If it compiles with a warning locally, it fails in CI. Clean it up.

**Credo runs on `--strict`.** Use the strict mode to catch code smells, complexity issues, and consistency violations. Not every Credo warning is worth fixing, but every ignored warning needs a comment explaining why.

```elixir
# credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
def complex_business_logic(params) do
  # This function has high complexity because it implements 
  # the Meta API rate limit state machine. Splitting it would
  # make the logic harder to follow.
end
```

**100% test coverage.** Every line of code has a test that exercises it. Use `mix coveralls.html` to see what's missing. Untested code is unfinished code.

**Coverage excludes are explicit.** If a module or function genuinely can't be tested (rare), mark it with `# coveralls-ignore-start` / `# coveralls-ignore-stop`. Document why in a comment. The default is: if it's worth writing, it's worth testing.

**CI fails on any gate failure.** Formatting, compiler warnings, Credo, test failures, coverage below 100% — any of these fails the build. Main stays clean because nothing merges until all gates pass.

**Git hooks are optional, `precommit` is not.** Some developers like pre-commit hooks to run quality checks automatically. Fine, but don't rely on them — hooks can be bypassed. The contract is: you run `mix precommit` and it passes before you push.

**Quality gates catch what reviews miss.** A reviewer shouldn't have to notice inconsistent formatting or a stray `IO.inspect`. Automate the mechanical checks so reviews focus on logic, architecture, and correctness.

**Fast feedback loop.** Quality gates run in seconds locally. If `mix precommit` takes more than 30 seconds, something's wrong (probably slow tests). Keep it fast so running the check doesn't feel like a chore.

**Document exceptions in the README.** If you genuinely need to disable a Credo check project-wide, do it in `.credo.exs` and explain why in a comment. If coverage can't hit 100% for a legitimate reason (not laziness), document it where the team can see it.

---

## 16. Security posture

**Treat all external input as hostile.** Meta API responses, user form fields, LLM outputs, ad creative text — all untrusted. Validate, sanitize, or parse into a typed struct at the boundary.

**LLM tool calls that modify state require explicit confirmation.** The pattern is in `decisions/0001-skip-rls-for-mvp.md` and the architecture doc: tool returns `{:error, :confirmation_required}` unless context has a valid token issued by a user click. No exceptions — a single prompt-injection-authorized pause is the kind of bug that ends the product.

**Tenant isolation is checked at the query layer, not at the view layer.** Never write `if current_user.id == ad.user_id do ... end` in a LiveView. The query shouldn't have returned someone else's ad in the first place.

**Every write operation gets logged to `actions_log`.** Who, what, when, why (LLM turn id if applicable). This is audit gold when something goes wrong.

---

## 17. Authentication — phx.gen.auth, Stateful Tokens

**Start with `phx.gen.auth`.** Don't roll your own authentication. Phoenix's official generator gives you bcrypt password hashing, remember-me tokens, session management, and email confirmation out of the box. It's audited, tested, and the right foundation.

**Sessions are stateful, stored in the database.** Use `UserToken` with a `context` field to distinguish session tokens from reset tokens from remember-me tokens. Every token has an expiry; no infinite sessions.

```elixir
# phx.gen.auth gives you this
defmodule AdButler.Accounts.UserToken do
  schema "users_tokens" do
    field :token, :binary
    field :context, :string  # "session", "reset_password", "confirm_email"
    field :sent_to, :string
    belongs_to :user, User

    timestamps(updated_at: false)
  end
end
```

**Tokens are hashed before storage.** The raw token lives in the cookie (or email link); the database stores `Base.url_encode64(:crypto.hash(:sha256, token), padding: false)`. Stolen database dumps don't yield working tokens.

**Session tokens expire.** 60 days for "remember me" checked, 24 hours otherwise. Config lives in `Accounts.UserToken.session_validity_in_days/0`. Rotate the value down if threat model changes.

**Logout invalidates the token.** Call `Accounts.delete_user_session_token/1`. The user's session ends everywhere that token was used. For "log out all devices," delete all tokens with `context: "session"` for that user.

**Password resets are one-time use.** `context: "reset_password"` tokens get deleted on use, whether the reset succeeds or fails. No retry attacks on the same link.

**Email confirmation links expire fast.** 7 days max. Old confirmation tokens get pruned via an Oban job (see section 3 — no GenServer for this).

**Don't leak user existence.** `Accounts.get_user_by_email_and_password/2` returns `nil` whether the email doesn't exist or the password is wrong. The error message to the user is always "Invalid email or password." Timing attacks are harder to avoid, but at least don't hand-deliver the list of registered emails.

**Two-factor auth, if needed, extends phx.gen.auth.** Add a `UserToken` context for TOTP secrets (encrypted via Cloak), add a verification step after password authentication. Don't rewrite the whole auth stack — extend the existing one.

**Never authenticate via URL query params.** Tokens in URLs get logged by proxies, browsers, and analytics. Tokens go in cookies (for sessions) or POST bodies (for API calls). The only exception: one-time email confirmation/reset links, which expire fast and get deleted on use.

**API authentication (if needed) uses separate tokens.** Don't reuse session cookies for API calls. Generate long-lived API tokens (still with expiry), store them hashed, scope them to specific permissions. Different `context` in `UserToken`, different validation logic.

---

## 18. Performance

**Measure before optimizing.** Fast-looking code that's not in the hot path wastes attention. Telemetry + OpenTelemetry traces tell you where the time actually goes.

**Postgres indexes are part of the schema.** Every query that matters has an index; every index has a query that uses it. `EXPLAIN ANALYZE` on any query that runs more than once per request.

**N+1 queries are bugs, not style issues.** Use `Ecto.Query.preload/2` or `Repo.preload/3` deliberately. `mix test --trace` + `Ecto.LogEntry` in dev catches these early.

**Bulk operations for anything over 10 rows.** `Repo.insert_all/3`, `Repo.update_all/3`, Meta API batch requests. Don't loop `Repo.insert` when you're processing ad insights.

---

## 19. Documentation

**Public functions have `@moduledoc` and `@doc`.** Private helpers don't need them unless the name isn't self-explanatory.

**`@spec` on public context functions.** Dialyzer catches more bugs than unit tests for pure-data code.

**Runbooks in `docs/runbooks/`.** Every operational task that could wake you up at 3am has a written runbook — restore from backup, rotate Cloak key, re-authenticate a user, kill-switch LLM spend. Write them when calm, use them when panicking.

**Decision records in `docs/decisions/`.** Every non-trivial choice (library, architecture pattern, trade-off) gets a DNNNN markdown file. Template is in the plan docs.

---

## 20. LiveView and UI

**LiveView assigns are for state the view renders.** Not scratch space; not intermediate data. If you need scratch, compute it in a function.

**Event handlers are thin.** `handle_event("pause_ad", ...)` calls into the `Ads` or `Chat` context and assigns the result. No business logic in the handler.

**Forms use `Ecto.Changeset`.** Even for non-DB forms. The changeset-based API is Phoenix's lingua franca and errors render for free.

**Components (`Phoenix.Component`) over render fragments.** A function that returns HEEx with props is cleaner than a sprawling LiveView template.

**Streams for list updates.** If a list could grow past a few hundred items, use `Phoenix.LiveView.stream/4`. Saves memory and makes pagination natural.

---

## 21. UI Components — No DaisyUI, Custom Tailwind, Mobile-First

**Never use DaisyUI components.** Pre-built component libraries lock you into someone else's design language. AdButler's UI is custom, intentional, and distinctive — that means writing components from scratch with Tailwind utilities.

**Every component is a `Phoenix.Component` with Tailwind classes.** No CSS files, no separate stylesheets, no utility class generators on top of Tailwind. The component owns its appearance via `class` attributes. Colocation makes iteration fast.

```elixir
def button(assigns) do
  ~H"""
  <button class="
    px-4 py-2 rounded-lg font-medium transition-colors
    bg-blue-600 hover:bg-blue-700 active:bg-blue-800
    text-white disabled:bg-gray-300 disabled:cursor-not-allowed
    focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2
  ">
    <%= render_slot(@inner_block) %>
  </button>
  """
end
```

**Mobile-first, always.** Every component starts with mobile layout, then uses `sm:`, `md:`, `lg:` breakpoints to enhance for larger screens. Don't design for desktop and retrofit mobile — that's how you get clunky, compromised UIs.

```elixir
# Mobile-first: stack vertically, then row on larger screens
def stat_card(assigns) do
  ~H"""
  <div class="
    flex flex-col gap-2
    md:flex-row md:items-center md:justify-between
    p-4 bg-white rounded-lg shadow
  ">
    <div class="text-sm text-gray-600"><%= @label %></div>
    <div class="text-2xl font-bold md:text-3xl"><%= @value %></div>
  </div>
  """
end
```

**Design tokens live in `tailwind.config.js`.** Brand colors, spacing scales, font families — extend Tailwind's defaults, don't fight them. This gives you `bg-brand-primary` instead of `bg-[#1e40af]` scattered everywhere.

```js
// tailwind.config.js
module.exports = {
  theme: {
    extend: {
      colors: {
        brand: {
          primary: '#0066cc',
          secondary: '#004d99',
          accent: '#ff6b35',
        },
      },
      // ... more tokens
    },
  },
}
```

**Components are composable.** A `<.card>` component wraps children. A `<.stat>` component goes inside. Don't create monolithic "dashboard_panel" components that do everything — build small pieces that combine.

**Accessibility is non-negotiable.** Every interactive element has proper ARIA attributes, keyboard navigation works, focus states are visible. Use semantic HTML (`<button>` not `<div onclick=...>`). Test with VoiceOver or NVDA before calling it done.

**Loading and empty states are first-class.** Every list has an empty state ("No ads yet — connect your Meta account"). Every async action has a loading state (spinner, skeleton, disabled button). Design these states, don't leave them as afterthoughts.

**Animations are purposeful and fast.** Transitions smooth state changes (`transition-colors duration-200`), but don't overdo it. No 800ms slide-ins, no bouncing modals. Respect `prefers-reduced-motion` for users who've opted out.

**Consistent, world-class means sweat the details.** Hover states on everything interactive. Consistent spacing (use Tailwind's scale, not arbitrary values). Proper typography hierarchy. Visual feedback for every user action. This is what separates "works" from "delightful."

---

## 22. When principles collide

When two principles tension each other (they will), the tiebreaker is: **what's best for the user's data integrity**, then **what's best for the next developer reading this code six months from now**, then **what's best for the author's convenience today**. In that order.

---

## 23. How this document changes

- Edits happen via PR to `CODING_PRINCIPLES.md`. The PR description says *why* the principle changed.
- Approved changes apply to future code; existing code gets updated opportunistically, not as a big-bang refactor.
- If a principle gets broken repeatedly, either the principle is wrong or the tooling to enforce it is missing. Revisit.

---

## Things not yet decided

Topics I haven't taken a position on, waiting for your call:

- **Code formatting strictness.** `mix format --check-formatted` in CI = mandatory? Or advisory?
- **Credo strictness level.** `--strict` catches more but rejects some idioms.
- **Dialyzer in CI.** Slows CI; catches real bugs. Worth it?
- **Typespec coverage target.** 100% public API? Only contexts? None?
- **Commit message format rigor.** Conventional Commits enforced by hook, or just encouraged?
- **Solo PR discipline.** Self-review + merge after 5 minutes? Or always wait a day?
- **Breakpoint / inspect discipline in committed code.** Zero tolerance? Or okay during feature development?

Add your positions, delete mine where you disagree, and this becomes the contract.
