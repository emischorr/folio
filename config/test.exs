import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :folio, Folio.Repo,
  username: "postgres",
  password: "postgres",
  hostname: System.get_env("PGHOST", "localhost"),
  database: "folio_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Oban: never run queues/plugins in test; jobs are exercised with Oban.Testing
config :folio, Oban, testing: :manual

# Route all Req HTTP traffic to test stubs; never hit the network
config :folio, :req_options, plug: {Req.Test, Folio.Clients}, retry: false

# Fast, weak hashes are fine in test
config :argon2_elixir, t_cost: 1, m_cost: 8

# Tests invoke Folio.Bootstrap.run/0 explicitly when they need it
config :folio, Folio.Bootstrap, enabled: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :folio, FolioWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "tSGTDQoHgdd7XOG2UrGTLUROn195F8DAKcGgYZAzEbKkDnatrBwtbngr/HhGFjJv",
  server: false

# In test we don't send emails
config :folio, Folio.Mailer, adapter: Swoosh.Adapters.Test

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
