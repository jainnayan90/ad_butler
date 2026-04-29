# Plan: Week 3 — Polish + Ship (Days 13–15)

**Branch:** create from `main` (or current feature branch)
**Depth:** Standard
**Source:** v0.2 plan Week 3 + v0.2-audit-fixes Phase 1 (pre-ship requirements)

---

## What Already Exists (v0.2 Week 2 baseline)

| Built | Location |
|---|---|
| `Analytics` context — findings, health scores, pagination | `lib/ad_butler/analytics.ex`, `lib/ad_butler/analytics/` |
| `BudgetLeakAuditorWorker` — all 5 heuristics + scoring | `lib/ad_butler/workers/budget_leak_auditor_worker.ex` |
| `AuditSchedulerWorker` — fans out per ad account | `lib/ad_butler/workers/audit_scheduler_worker.ex` |
| `FindingsLive` — list + filters + pagination | `lib/ad_butler_web/live/findings_live.ex` |
| `FindingDetailLive` — detail + acknowledge | `lib/ad_butler_web/live/finding_detail_live.ex` |
| `AdButler.Mailer` — Swoosh configured, `Local` adapter in dev | `lib/ad_butler/mailer.ex`, `config/config.exs:37` |
| `llm_pricing` migration + schema (no rows seeded yet) | `priv/repo/migrations/20260420155226_create_llm_pricing.exs` |
| `fly.staging.toml` + hardened `runtime.exs` | `fly.staging.toml`, `config/runtime.exs` |

---

## Architecture Decisions

- **`AdButler.Notifications` context** owns digest email logic. Workers live under
  `AdButler.Workers`. The context is the only caller of `AdButler.Mailer`.
- **SMTP adapter** in production via `Swoosh.Adapters.SMTP`. Adapter, host, port,
  username, and password come from runtime env (`config/runtime.exs`). Dev keeps
  `Swoosh.Adapters.Local`.
- **DigestWorker fires per user** — one Oban job per user, not a bulk blast. The
  scheduler fans out; the worker handles one user. Idempotent: no-op when 0
  high/medium findings.
- **"From" address** is `noreply@{PHX_HOST}` (derived from existing `PHX_HOST` env
  var — no new env var needed for the sender address).
- **Iron Law / Arch fixes** are prerequisite to shipping — design partners will hit
  the `String.to_integer` crash on any URL manipulation. These ship in the same PR
  as the feature work.

---

## Phase 1 — Iron Law Fixes (pre-ship, highest priority)

These come from `v0.2-audit-fixes` Phase 1. They are blocking because they
represent crashes or context-boundary violations that affect correctness in prod.

### SEC-1 · Fix `parse_page/1` crash in 4 LiveViews

`String.to_integer/1` raises on any non-numeric `?page=` param. Replace with
safe `Integer.parse/1` pattern in all four LiveViews.

- [x] [liveview] Replace `parse_page/1` in `dashboard_live.ex`, `campaigns_live.ex`,
  `ad_sets_live.ex`, `ads_live.ex` with:
  ```elixir
  defp parse_page(nil), do: 1
  defp parse_page(p) when is_binary(p) do
    case Integer.parse(p) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end
  ```

### SEC-2 · Fix Logger string interpolation in `auth_controller.ex`

- [x] [liveview] In `auth_controller.ex:77`, change:
  ```elixir
  # before
  Logger.error("OAuth failure reason=#{inspect(reason)}")
  # after
  Logger.error("oauth_failure", reason: inspect(reason))
  ```

### ARCH-1 · Move Repo out of workers → `Analytics` context

Three workers (`MatViewRefreshWorker`, `PartitionManagerWorker`,
`SyncAllConnectionsWorker`) call `Repo` directly — violates context boundary.

- [x] [ecto] Expand `lib/ad_butler/analytics.ex` with partition/view management
  functions (may already exist; verify and add missing ones):
  - `refresh_view/1` — `"7d" | "30d"` → executes `REFRESH MATERIALIZED VIEW CONCURRENTLY`, returns `:ok`
  - `list_partition_names/0` — executes `pg_inherits` query, returns `[String.t()]`
  - `create_future_partitions/0` — creates next 2 weekly partitions idempotently
  - `detach_old_partitions/0` — detaches partitions older than 13 months
  - `check_future_partition_count/0` — logs error if fewer than 2 future partitions

- [x] [oban] Refactor `MatViewRefreshWorker.perform/1` to call
  `Analytics.refresh_view/1`; remove direct `Repo` alias from the worker

- [x] [oban] Refactor `PartitionManagerWorker.perform/1` to call
  `Analytics.create_future_partitions/0`, `Analytics.detach_old_partitions/0`,
  `Analytics.check_future_partition_count/0`; remove direct `Repo` alias

- [x] [ecto] Add `Accounts.stream_connections_and_run/1` to `accounts.ex`:
  ```elixir
  @doc "Runs `fun` inside a transaction with a stream of active MetaConnections."
  @spec stream_connections_and_run((Enumerable.t() -> any()), keyword()) :: {:ok, any()} | {:error, term()}
  def stream_connections_and_run(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, :timer.minutes(2))
    Repo.transaction(fn -> fun.(stream_active_meta_connections()) end, timeout: timeout)
  end
  ```

- [x] [oban] Refactor `SyncAllConnectionsWorker.perform/1` to use
  `Accounts.stream_connections_and_run/1`; remove direct `Repo` alias

### ARCH-2 · Move Repo out of `HealthController`

- [x] [ecto] Create `lib/ad_butler/health.ex`:
  ```elixir
  defmodule AdButler.Health do
    @moduledoc "Internal health checks."
    alias AdButler.Repo
    alias Ecto.Adapters.SQL

    @doc "Pings the database. Returns `{:ok, _}` or `{:error, _}`."
    def db_ping do
      SQL.query(Repo, "SELECT 1", [], timeout: 1_000, queue_target: 200)
    end
  end
  ```

- [x] [ecto] In `health_controller.ex`, replace `default_db_ping/0` body with
  `AdButler.Health.db_ping()`; remove `alias AdButler.Repo` and
  `alias Ecto.Adapters.SQL`

### ARCH-3 · Fix `ConnectionsLive` — stream, pagination, `connected?` gate

- [x] [ecto] Add `paginate_meta_connections/2` to `accounts.ex`:
  ```elixir
  @doc """
  Returns a page of MetaConnections for `user` and the total count.
  Options: `:page` (default 1), `:per_page` (default 50).
  """
  @spec paginate_meta_connections(User.t(), keyword()) :: {[MetaConnection.t()], non_neg_integer()}
  def paginate_meta_connections(%User{id: user_id}, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 50)
    base = from(mc in MetaConnection, where: mc.user_id == ^user_id, order_by: [desc: mc.inserted_at])
    total = Repo.aggregate(base, :count)
    items = base |> limit(^per_page) |> offset(^((page - 1) * per_page)) |> Repo.all()
    {items, total}
  end
  ```

- [x] [liveview] Refactor `ConnectionsLive`:
  - `mount/3`: gate DB call behind `connected?(socket)` — static render gets
    empty stream and `total_pages: 1`
  - `handle_params/3`: read `page` param (via `parse_page/1`), call
    `paginate_meta_connections/2`, `stream(:connections, items, reset: true)`
  - Remove plain `:connections` list assign; template loops `@streams.connections`
  - Assign `:page`, `:total_pages`, `:connection_count`
  - Add `<.pagination page={@page} total_pages={@total_pages} />` in template

### ARCH-4 · Move Repo out of `LLM.UsageHandler`

- [x] [ecto] Add `insert_usage/1` to `lib/ad_butler/llm.ex`:
  ```elixir
  @doc false
  def insert_usage(attrs) when is_map(attrs) do
    changeset = Usage.changeset(%Usage{}, attrs)
    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:request_id]) do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end
  ```

- [x] [ecto] Update `UsageHandler` to call `AdButler.LLM.insert_usage(attrs)`;
  remove `alias AdButler.Repo` and `alias AdButler.LLM.Usage`

### Phase 1 Tests

- [x] [testing] Create `test/ad_butler/llm_test.exs`:
  - `list_usage_for_user/2` — returns own rows, tenant isolation (user B sees nothing)
  - `total_cost_for_user/1` — sums correctly, tenant isolation
  - `get_usage!/2` — returns row for owner; raises for wrong user

- [x] [testing] Create or expand `test/ad_butler/ads_test.exs`:
  - `paginate_campaigns/2` — correct page/total + tenant isolation
  - `paginate_ad_sets/2` — correct page/total + tenant isolation
  - `paginate_ads/2` — correct page/total + tenant isolation
  - `paginate_ad_accounts/2` — correct page/total + tenant isolation
  - Each isolation test: insert data for user A, assert user B gets `{[], 0}`

---

## Phase 2 — Email Digest (Day 13)

### P13-T1 · Configure Swoosh production adapter

- [x] [ecto] In `config/runtime.exs`, add a production mailer config block:
  ```elixir
  if config_env() == :prod do
    config :ad_butler, AdButler.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: System.fetch_env!("SMTP_HOST"),
      port: System.get_env("SMTP_PORT", "587") |> String.to_integer(),
      username: System.fetch_env!("SMTP_USERNAME"),
      password: System.fetch_env!("SMTP_PASSWORD"),
      tls: :always,
      auth: :always
  end
  ```

- [x] [ecto] Add to `.env.example`:
  ```
  # --- Email (production SMTP) ---
  SMTP_HOST=
  SMTP_PORT=587
  SMTP_USERNAME=
  SMTP_PASSWORD=
  ```

### P13-T2 · `AdButler.Notifications` context + `DigestMailer`

- [x] [ecto] Create `lib/ad_butler/notifications.ex`:
  ```elixir
  defmodule AdButler.Notifications do
    @moduledoc "Email digest and notification delivery."

    alias AdButler.{Analytics, Accounts, Mailer}
    alias AdButler.Notifications.DigestMailer

    @doc "Delivers a digest email to `user` for the given period. Returns `:ok` or `{:skip, reason}`."
    @spec deliver_digest(User.t(), String.t()) :: :ok | {:skip, :no_findings}
    def deliver_digest(user, period) when period in ["daily", "weekly"] do
      hours = if period == "daily", do: 24, else: 168
      since = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
      findings = Analytics.list_high_medium_findings_since(user, since)

      if findings == [] do
        {:skip, :no_findings}
      else
        email = DigestMailer.build(user, findings, period)
        Mailer.deliver(email)
        :ok
      end
    end
  end
  ```

- [x] [ecto] Add `list_high_medium_findings_since/2` to `lib/ad_butler/analytics.ex`:
  returns findings with `severity IN ('high', 'medium')` and `inserted_at >= since`,
  scoped via `ad_account_id IN (...)` using mc_ids from user.

- [x] [ecto] Create `lib/ad_butler/notifications/digest_mailer.ex` — Swoosh email:
  ```elixir
  defmodule AdButler.Notifications.DigestMailer do
    @moduledoc false
    import Swoosh.Email

    @from_name "AdButler"

    def build(user, findings, period) do
      count = length(findings)
      subject = "AdButler: #{count} new #{severity_label(findings)} findings (#{period})"

      new()
      |> to({user.email, user.email})
      |> from({"AdButler", "noreply@adbutler.app"})
      |> subject(subject)
      |> text_body(text_body(findings, period))
      |> html_body(html_body(findings, period))
    end

    defp severity_label(findings) do
      if Enum.any?(findings, &(&1.severity == "high")), do: "high-severity", else: "medium-severity"
    end

    defp text_body(findings, period) do
      header = "Your #{period} AdButler digest:\n\n"
      rows = Enum.map_join(findings, "\n", &"- [#{&1.severity |> String.upcase()}] #{&1.title}")
      header <> rows <> "\n\nLog in at https://adbutler.app/findings to review."
    end

    defp html_body(findings, period) do
      rows = Enum.map_join(findings, "", fn f ->
        badge_color = if f.severity == "high", do: "#dc2626", else: "#d97706"
        "<tr><td style='padding:8px'><span style='color:#{badge_color};font-weight:bold'>#{String.upcase(f.severity)}</span></td><td style='padding:8px'>#{f.title}</td></tr>"
      end)
      """
      <html><body style='font-family:sans-serif'>
      <h2>Your #{period} AdButler digest</h2>
      <table border='0' cellpadding='0' cellspacing='0'>#{rows}</table>
      <p><a href='https://adbutler.app/findings'>Review findings →</a></p>
      </body></html>
      """
    end
  end
  ```

### P13-T3 · `DigestWorker` Oban job

- [x] [oban] Create `lib/ad_butler/workers/digest_worker.ex`:
  ```elixir
  defmodule AdButler.Workers.DigestWorker do
    @moduledoc "Delivers a digest email for one user."
    use Oban.Worker, queue: :notifications, max_attempts: 3

    alias AdButler.{Accounts, Notifications}

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"user_id" => user_id, "period" => period}}) do
      user = Accounts.get_user!(user_id)

      case Notifications.deliver_digest(user, period) do
        :ok -> :ok
        {:skip, :no_findings} -> :ok
      end
    end
  end
  ```

### P13-T4 · `DigestSchedulerWorker` Oban cron

- [x] [oban] Create `lib/ad_butler/workers/digest_scheduler_worker.ex`:
  ```elixir
  defmodule AdButler.Workers.DigestSchedulerWorker do
    @moduledoc "Fans out DigestWorker jobs for all users with active connections."
    use Oban.Worker, queue: :default, max_attempts: 3

    alias AdButler.{Accounts, Workers.DigestWorker}

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"period" => period}}) do
      users = Accounts.list_users_with_active_connections()

      jobs = Enum.map(users, fn user ->
        DigestWorker.new(%{"user_id" => user.id, "period" => period})
      end)

      Oban.insert_all(jobs)
      :ok
    end
  end
  ```

- [x] [ecto] Add `Accounts.list_users_with_active_connections/0` to `accounts.ex` —
  returns distinct users who have at least one `MetaConnection` in `:active` status.
  Scoped query — no cross-user concern here (returns all users for scheduler use).

- [x] [oban] Register crons in `config/config.exs` alongside existing Oban cron entries:
  ```elixir
  %{cron: "0 8 * * *",   worker: "AdButler.Workers.DigestSchedulerWorker", args: %{period: "daily"}},
  %{cron: "0 8 * * 1",   worker: "AdButler.Workers.DigestSchedulerWorker", args: %{period: "weekly"}},
  ```

- [x] [oban] Add `:notifications` queue to Oban queues config in `config/config.exs`:
  `{:notifications, 5}` (low concurrency — email sending is slow)

### P13-T5 · Email Digest Tests

- [x] [testing] Create `test/ad_butler/notifications/digest_mailer_test.exs`:
  - `build/3` returns email with correct subject, `to` field, non-empty text and HTML body
  - subject contains "high-severity" when any finding has severity "high"
  - subject contains "medium-severity" when all findings are medium

- [x] [testing] Create `test/ad_butler/workers/digest_worker_test.exs`:
  - `perform/1` with 0 high/medium findings — returns `:ok`, no email delivered
  - `perform/1` with N findings — returns `:ok`, email delivered once (use `Swoosh.TestAssertions`)
  - `perform/1` for unknown user_id — verify it raises appropriately (Oban retries)

- [x] [testing] Create `test/ad_butler/workers/digest_scheduler_worker_test.exs`:
  - `perform/1` — fans out correct number of `DigestWorker` jobs for N users with active connections
  - `perform/1` — skips users with no active connections

---

## Phase 3 — E2E Validation (Day 14)

- [x] Run `mix test` — all tests pass (346 tests, 0 failures)

- [x] Run `mix precommit` — clean compile (warnings-as-errors), format, all tests green

- [ ] Manual smoke test with seeded data:
  - Start server (`mix phx.server`)
  - Verify `/findings` renders with pagination, filters work without crash
  - Manually trigger digest via `iex -S mix` + `Oban.insert(DigestSchedulerWorker.new(%{"period" => "daily"}))`
  - Verify Swoosh local inbox at `/dev/mailbox` shows the digest email
  - Verify acknowledge button works in FindingDetailLive

- [ ] Verify partition health: `mix run -e 'IO.inspect AdButler.Analytics.check_future_partition_count()'`

- [ ] Verify materialized views: `mix run -e 'AdButler.Analytics.refresh_view("7d")'` returns `:ok`

---

## Phase 4 — Design Partner Prep (Day 15)

### P15-T1 · Seed `llm_pricing` rows

- [x] [ecto] Add to `priv/repo/seeds.exs`:
  ```elixir
  now = DateTime.utc_now() |> DateTime.truncate(:second)

  llm_pricing_rows = [
    %{provider: "anthropic", model: "claude-sonnet-4-6", cents_per_1k_input: Decimal.new("0.03"), cents_per_1k_output: Decimal.new("0.15"), effective_from: ~D[2025-01-01], effective_to: nil, inserted_at: now},
    %{provider: "anthropic", model: "claude-haiku-4-5-20251001", cents_per_1k_input: Decimal.new("0.008"), cents_per_1k_output: Decimal.new("0.04"), effective_from: ~D[2025-01-01], effective_to: nil, inserted_at: now},
    %{provider: "openai", model: "text-embedding-3-small", cents_per_1k_input: Decimal.new("0.0002"), cents_per_1k_output: Decimal.new("0.0"), effective_from: ~D[2024-01-01], effective_to: nil, inserted_at: now},
  ]

  Enum.each(llm_pricing_rows, fn row ->
    AdButler.Repo.insert_all("llm_pricing", [row],
      on_conflict: :nothing,
      conflict_target: [:provider, :model, :effective_from])
  end)
  ```

### P15-T2 · Decisions document

- [x] Create `docs/plan/decisions/0005-findings-dedup-strategy.md` documenting:
  - Decision: deduplicate findings by `(ad_id, kind)` — skip insert if unresolved
    finding of same kind already exists
  - Resolution policy: "resolved" means `resolved_at IS NOT NULL`; only create a new
    finding when the previous one is resolved or it's the first occurrence
  - Tradeoff: simpler than time-window dedup; may delay re-alerting after resolve
    if root cause persists; acceptable for v0.2 with manual review expected

### P15-T3 · Staging deploy (from `week3-liveview-ui-deploy` — manual steps)

- [ ] Provision CloudAMQP staging instance (free tier); save connection URL for
  `RABBITMQ_URL` Fly secret

- [ ] Provision Fly Postgres for staging:
  ```
  fly postgres create --name ad-butler-staging-db
  fly postgres attach ad-butler-staging-db -a ad-butler-staging
  ```

- [ ] Set Fly secrets on staging app:
  ```
  fly secrets set -a ad-butler-staging \
    DATABASE_URL=... \
    SECRET_KEY_BASE=$(mix phx.gen.secret) \
    RABBITMQ_URL=... \
    CLOAK_KEY=$(openssl rand -base64 32) \
    META_APP_ID=... \
    META_APP_SECRET=... \
    META_OAUTH_CALLBACK_URL=https://ad-butler-staging.fly.dev/auth/meta/callback \
    LIVE_VIEW_SIGNING_SALT=$(mix phx.gen.secret 32) \
    SMTP_HOST=... \
    SMTP_PORT=587 \
    SMTP_USERNAME=... \
    SMTP_PASSWORD=...
  ```

- [ ] Deploy with build secrets:
  ```
  fly deploy --config fly.staging.toml \
    --build-secret SESSION_SIGNING_SALT=... \
    --build-secret SESSION_ENCRYPTION_SALT=...
  ```

- [ ] Smoke test staging:
  - `curl https://ad-butler-staging.fly.dev/health/liveness` → `{"status":"ok"}`
  - `curl https://ad-butler-staging.fly.dev/health/readiness` → `{"status":"ok"}`
  - Complete OAuth flow end-to-end in browser
  - Check `/findings` renders (may be empty — that's fine)
  - Check Oban queues registered correctly (via `iex --remsh`)

### P15-T4 · Onboarding checklist for design partner

- [x] Create `docs/design-partner-onboarding.md`:
  1. Connect Meta account → `/connections/new`
  2. Wait ~30 min for first insights sync (InsightsSchedulerWorker runs every 30 min)
  3. Auditor runs every 6h after metadata sync — check `/findings` after ~7h from connect
  4. Daily digest email arrives at 8am UTC if any high/medium findings exist
  5. Acknowledge findings to track triage progress

### P15-T5 · Final verification

- [x] `mix precommit` — final gate (must be clean before shipping)
- [ ] Submit Meta App Review for production `app_id` (manual — open Meta developer console)

---

## Iron Law Checks

- All `Analytics` queries scoped via `ad_account_id IN (SELECT id FROM ad_accounts WHERE meta_connection_id IN ^mc_ids)` — tenant isolation maintained ✓
- `DigestWorker` queries findings through `Notifications.deliver_digest/2` → `Analytics.list_high_medium_findings_since/2` — scoped via mc_ids ✓
- No unbounded list loads — digest caps findings via scoped query; connections paginated ✓
- `digest_scheduler_worker` skips users with 0 active connections → no spurious email jobs ✓
- SMTP credentials are runtime env vars, never in config files ✓

---

## Risks

1. **Swoosh SMTP adapter in tests**: `Swoosh.TestAssertions` requires `config :swoosh, :api_client, Swoosh.ApiClient.Finch` to be unset in test config — or use `Swoosh.Adapters.Test`. Verify `config/test.exs` has `adapter: Swoosh.Adapters.Test` (it likely does from Phoenix boilerplate).

2. **`list_high_medium_findings_since/2` query shape**: The Analytics context will need the user's mc_ids to scope findings. Use the same `Accounts.list_meta_connection_ids_for_user/1` pattern used elsewhere — don't pass user struct into Analytics directly.

3. **Staging deploy order matters**: Postgres must be attached before `fly deploy` runs migrations. If deploy fails with "relation does not exist," the DB attach step was skipped.

4. **MetaConnection `stream_active_meta_connections/0`**: `Accounts.stream_connections_and_run/1` calls this — verify the function signature matches (takes no args, returns a queryable). If the existing function has a different name, update the wrapper accordingly.

5. **ConnectionsLive `connected?` gate**: If connections page tests use `render_hook` / `live/2` they will hit `connected? == true` in test context. Static render path (dead view) shows empty stream — ensure tests cover both paths to avoid false negatives.
