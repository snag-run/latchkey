import Config
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Don't boot Commanded in the sandboxed suite; integration tests start it explicitly.
config :latchkey, start_commanded: false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :latchkey, Latchkey.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "latchkey_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Commanded EventStore — shares the Repo's test database, isolated in its own
# `event_store` schema. Not sandboxed: Commanded runs outside the Ecto sandbox,
# so integration tests start the app and use unique streams.
config :latchkey, Latchkey.EventStore,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "latchkey_test#{System.get_env("MIX_TEST_PARTITION")}",
  schema: "event_store",
  port: 5432,
  pool_size: 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :latchkey, LatchkeyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "jfXDVIvzCW3lE2CeZxq8HVuNg5Jbd/Ly9yHd5r2hbBdD1Qy0SFtj8jfscfa/0gAX",
  server: false

# In test we don't send emails
config :latchkey, Latchkey.Mailer, adapter: Swoosh.Adapters.Test

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
