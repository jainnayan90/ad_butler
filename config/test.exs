import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ad_butler, AdButler.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ad_butler_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ad_butler, AdButlerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "VoevhJEIosVk7fwab3T1MlDYFT+P9HaHzq6zEqM4sA0DqCeP/sjQVCy265/0+UR+",
  server: false

# In test we don't send emails
config :ad_butler, AdButler.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :ad_butler, session_secure_cookie: false

config :ad_butler,
  session_signing_salt: "test_signing_salt",
  session_encryption_salt: "test_encrypt_salt"

config :ad_butler, AdButlerWeb.Endpoint, live_view: [signing_salt: "test_lv_salt"]

config :ad_butler, :meta_client, AdButler.Meta.ClientMock

config :ad_butler, :rabbitmq, url: "amqp://guest:guest@localhost:5672"

config :ad_butler, :messaging_publisher, AdButler.Messaging.PublisherMock

config :ad_butler, :embeddings_service, AdButler.Embeddings.ServiceMock

config :ad_butler, :chat_llm_client, AdButler.Chat.LLMClientMock

config :ad_butler, :broadway_producer, :test

config :ad_butler, Oban, testing: :manual

config :ad_butler, AdButler.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("YWRfYnV0bGVyX3Rlc3Rfa2V5X2Zvcl90ZXN0aW5nISE=")}
  ]

config :ad_butler,
  meta_app_id: "test_meta_app_id",
  meta_app_secret: "test_meta_app_secret",
  meta_oauth_callback_url: "http://localhost/auth/meta/callback"
