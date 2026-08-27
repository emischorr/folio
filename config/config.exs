# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Market timezones (Folio.MarketData.Markets). :tz ships the IANA table and never
# touches the network; updates arrive with the dependency, which is fine for trading hours.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :folio,
  ecto_repos: [Folio.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :folio, FolioWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FolioWeb.ErrorHTML, json: FolioWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Folio.PubSub,
  live_view: [signing_salt: "/T9d2up8"]

# Oban background jobs
config :folio, Oban,
  engine: Oban.Engines.Basic,
  repo: Folio.Repo,
  queues: [market_data: 2],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/15 * * * *", Folio.MarketData.Workers.RefreshCryptoPrices},
       {"*/30 * * * *", Folio.MarketData.Workers.RefreshSecurityPrices},
       {"15 0 * * *", Folio.MarketData.Workers.NightlyRollup}
     ]}
  ]

# Source chains per concern, tried in order; first success wins. Adding or
# reordering a source is config, not code. See Folio.MarketData.Chain.
config :folio, :market_data_sources,
  security: [
    lookup: [Folio.MarketData.Sources.OpenFigi, Folio.MarketData.Sources.Yahoo],
    history: [Folio.MarketData.Sources.Yahoo],
    quote: [
      Folio.MarketData.Sources.Tradegate,
      Folio.MarketData.Sources.BoerseFrankfurt,
      Folio.MarketData.Sources.Yahoo
    ]
  ],
  crypto: [
    lookup: [Folio.MarketData.Sources.CoinGecko],
    history: [Folio.MarketData.Sources.CoinGecko],
    quote: [Folio.MarketData.Sources.CoinGecko]
  ],
  fx: Folio.MarketData.Sources.Frankfurter

# Per-source knobs. Overrides pin the rare listing whose vendor naming breaks
# the rule; they live in source config, never on assets.
config :folio, Folio.MarketData.Sources.CoinGecko,
  id_overrides: %{"BTC" => "bitcoin", "ETH" => "ethereum"},
  id_ttl_ms: :timer.hours(24)

config :folio, Folio.MarketData.Sources.Yahoo, symbol_overrides: %{}

# Per-source request budgets (token buckets, Folio.MarketData.RateLimiter).
# Conservative by design: an empty bucket makes the chain fall through to the
# next source rather than hammering a free endpoint.
config :folio, :rate_limits,
  tradegate: [capacity: 5, per_minute: 60],
  boerse_frankfurt: [capacity: 5, per_minute: 30],
  yahoo: [capacity: 3, per_minute: 5],
  coin_gecko: [capacity: 5, per_minute: 10],
  open_figi: [capacity: 10, per_minute: 25],
  frankfurter: [capacity: 10, per_minute: 60]

# Market-data lookup cache (Folio.MarketData.Cache TTLs). Free search endpoints
# are rate-limited per IP, so hits are held for minutes and 429s are remembered
# briefly. See README "External data sources".
config :folio, :search_cache, ok_ttl_ms: :timer.minutes(10), error_ttl_ms: :timer.seconds(60)

# Defaults the dashboard UI reads (iteration 2)
config :folio, :dashboard,
  window: :"1w",
  mode: :value,
  currency: "EUR"

# Idempotent boot-time setup (default user + portfolio)
config :folio, Folio.Bootstrap, enabled: true

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :folio, Folio.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  folio: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  folio: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
