import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/folio start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :folio, FolioWeb.Endpoint, server: true
end

# PREVIEW_PORT is exported by CodeLead for the previewed dev server; PORT still
# wins, and both unset leaves the usual 4000.
port = String.to_integer(System.get_env("PORT") || System.get_env("PREVIEW_PORT") || "4000")

config :folio, FolioWeb.Endpoint, http: [port: port]

# Optional CoinGecko demo API key: raises the public rate limit from ~5-15
# to 100 requests/minute. See README "Data sources".
config :folio, :coingecko_api_key, System.get_env("COINGECKO_API_KEY")

# Password for the bootstrapped Admin user. Hashed once on first creation;
# changing it later has no effect until a real login flow manages passwords.
config :folio, Folio.Bootstrap, admin_password: System.get_env("ADMIN_PASSWORD", "admin")

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :folio, FolioWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/folio_web/router\.ex$"E,
        ~r"lib/folio_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :folio, Folio.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Blank counts as unset: a compose file that passes a variable through
  # unconditionally would otherwise leave it set to "".
  env = fn name ->
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  # Folio serves plain HTTP: reach it directly by IP or hostname, or put your own
  # reverse proxy in front to terminate TLS. SCHEME and URL_PORT only describe how a
  # browser reaches it, so generated links and the session cookie come out right --
  # the app itself always listens on plain HTTP (PORT).
  host = env.("PHX_HOST") || "localhost"
  scheme = env.("SCHEME") || "http"

  url_port =
    case env.("URL_PORT") do
      nil -> if scheme == "https", do: 443, else: port
      value -> String.to_integer(value)
    end

  # Phoenix compares only the host of the websocket Origin against url[:host], so
  # PHX_HOST has to match what is typed in the address bar. CHECK_ORIGIN is the escape
  # hatch when Folio is reached under several names: a comma-separated list of allowed
  # origins, or "false" to skip the check entirely.
  check_origin =
    case env.("CHECK_ORIGIN") do
      nil -> true
      "true" -> true
      "false" -> false
      list -> list |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end

  config :folio, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :folio, :https_url?, scheme == "https"

  config :folio, FolioWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## TLS
  #
  # Folio does not terminate TLS itself. Put a reverse proxy (Caddy, nginx, Traefik,
  # ...) in front of it, point that proxy at PORT over plain HTTP, and set
  # SCHEME=https so Folio knows how browsers reach it. The proxy also owns the
  # http -> https redirect and any HSTS header.
  #
  # URL_PORT overrides the port used in generated URLs when the proxy listens on
  # something other than 443 (https) or PORT (http).

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :folio, Folio.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
