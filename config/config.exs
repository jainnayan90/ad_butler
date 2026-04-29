# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ad_butler,
  ecto_repos: [AdButler.Repo],
  generators: [timestamp_type: :utc_datetime],
  trusted_proxy: false,
  env: config_env()

# Configure the endpoint
# Session salts (session_signing_salt, session_encryption_salt) are baked into the release
# image for prod (compile_env! for the LiveView socket, fetch_env! for the HTTP session plug).
# They are set per-environment in dev.exs/test.exs. LiveView signing_salt is runtime-only:
# it is read from LIVE_VIEW_SIGNING_SALT at startup (see runtime.exs).
config :ad_butler, AdButlerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AdButlerWeb.ErrorHTML, json: AdButlerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AdButler.PubSub

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ad_butler, AdButler.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ad_butler: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  theme: [
    args: ~w(js/theme.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  ad_butler: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :worker,
    :id,
    :kind,
    :reason,
    :queue,
    :user_id,
    :meta_connection_id,
    :ad_account_id,
    :campaigns,
    :ad_sets,
    :ads,
    :count,
    :meta_id,
    :connection_count,
    :replayed,
    :replayed_so_far,
    :exchange,
    :dlq,
    :delay_ms,
    :meta_ids,
    :attempts_left,
    :limit,
    :errors,
    :meta_connection_ids,
    :newly_enqueued,
    :skipped,
    :sync_type,
    :usage,
    :partition,
    :week_start,
    :view,
    :duration_ms,
    :delivery_queue,
    :conversions_queue,
    :meta_connection_count,
    :description,
    :date_start,
    :dropped,
    :ad_id,
    :finding_id,
    :ads_audited,
    :failure_count
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "access_token",
  "client_secret",
  "code",
  "fb_exchange_token",
  "token",
  "cloak_key",
  "signing_salt",
  "encryption_salt"
]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# sync: 20 concurrency requires POOL_SIZE >= 25 in prod (20 workers + headroom for web/cron)
config :ad_butler, Oban,
  repo: AdButler.Repo,
  queues: [default: 10, sync: 20, analytics: 5, audit: 5],
  plugins: [
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"0 */6 * * *", AdButler.Workers.TokenRefreshSweepWorker},
       {"5 */6 * * *", AdButler.Workers.SyncAllConnectionsWorker},
       {"0 3 * * 0", AdButler.Workers.PartitionManagerWorker},
       {"*/15 * * * *", AdButler.Workers.MatViewRefreshWorker, args: %{"view" => "7d"}},
       {"0 * * * *", AdButler.Workers.MatViewRefreshWorker, args: %{"view" => "30d"}},
       {"*/30 * * * *", AdButler.Workers.InsightsSchedulerWorker},
       {"0 */2 * * *", AdButler.Workers.InsightsConversionWorker},
       {"3 */6 * * *", AdButler.Workers.AuditSchedulerWorker}
     ]}
  ]

import_config "#{config_env()}.exs"
