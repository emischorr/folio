# Folio

**A self-hosted portfolio tracker for crypto, stocks and ETFs.** You enter your
transactions; Folio fetches prices and exchange rates in the background and shows
what your portfolio is worth over time. Everything stays on your server.

**What it isn't:** no ads, no tracking, no sign-up, no premium tier, no news feed,
no social features, no broker linking. One portfolio, one chart, one list of
holdings — and nothing else competing for your attention.

![Folio dashboard](docs/images/folio_dashboard.png)

## What it does

- **Manual transactions** — buy or sell, with asset, date and time, quantity,
  price per unit, fee and currency. Edit or delete any of them later.
- **Asset lookup** — autocomplete across your own assets, CoinGecko and Yahoo
  Finance, with a manual-ticker fallback for when remote search is unavailable.
- **Value and profit over time** — an interactive chart over 1d, 1w, 1m, YTD, 1y
  or max, with a Value ↔ Profit toggle.
- **Per-asset holdings** — quantity, current value, change over the selected
  window and a sparkline; click through for that asset's transaction history.
- **Currency switch** — view everything in EUR or USD, converted per timestamp
  through daily ECB rates.
- **Honest numbers** — cost basis is locked in the portfolio's base currency at
  execution time, and money paid in during a window is not counted as profit.
- **Live updates** — background price and FX refreshes push straight into the
  open page. No reloading.
- **Light, dark or system theme.**

## Status

v0.1, and built for a single person on a single machine. One portfolio, one
bootstrapped user, and no login flow yet — the session simply acts as the `Admin`
user. There is no CSV or broker import, no dividend tracking, and no JSON API.

## Quick start

Requires Elixir 1.20 / OTP 28 (see `.tool-versions`) and Docker for PostgreSQL.

```sh
docker compose up -d postgresql   # Postgres 16 on :5432
mix setup                         # deps, database, seeds, assets
mix phx.server                    # http://localhost:4000
```

`mix setup` seeds a sample portfolio — Bitcoin, a EUR-quoted MSCI World ETF and
NVIDIA in USD — with two years of transactions and locally generated price and FX
history. A fresh checkout therefore opens on a populated dashboard without any
external API being touched.

## Configuration

Environment variables are read in `config/runtime.exs`, and nowhere else.

| Variable | Default | Purpose |
|---|---|---|
| `ADMIN_PASSWORD` | `admin` | Password for the bootstrapped user, hashed once on first boot |
| `COINGECKO_API_KEY` | — | Optional free demo key; raises the crypto rate limit to 100 req/min |
| `DATABASE_URL` | — | Required in production |
| `SECRET_KEY_BASE` | — | Required in production |
| `PHX_HOST` | `localhost` | Hostname or IP you reach Folio at — must match the address bar |
| `PORT` | `4000` | Port Folio listens on |
| `SCHEME` | `http` | Set to `https` when a proxy in front terminates TLS |
| `URL_PORT` | `PORT`, or `443` when `SCHEME=https` | Public port used in generated URLs |
| `CHECK_ORIGIN` | `PHX_HOST` | Comma-separated allowed websocket origins, or `false` to disable the check |

## Deployment

`docs/deployment/` holds a Docker Compose example built around the published image
(`ghcr.io/emischorr/folio`) and a Postgres service.

Folio serves **plain HTTP** and never terminates TLS itself. Reach it directly at
`http://<host>:4000`, or put your own reverse proxy in front — the proxy owns the
certificate, the `http` → `https` redirect and any HSTS header. When you do, set
`SCHEME=https` so links and the session cookie match what the browser sees.

Set `PHX_HOST` to the host or IP you actually type into the address bar. Phoenix
checks the websocket origin against it, so a mismatch leaves the page rendered but
dead — no live updates. Use `CHECK_ORIGIN` when Folio is reachable under more than
one name.

> **Upgrading from an earlier build?** It sent an HSTS header, so your browser may
> still force `https://` for that hostname. Clear the pin via
> `chrome://net-internals/#hsts` (or the Firefox equivalent) before plain HTTP loads.

## External data sources

Prices and FX rates are fetched in the background by Oban workers. Every provider
sits behind a behaviour, so swapping one means implementing that behaviour and
changing a single line in `config :folio, :clients`.

| Data | Provider | Limits and caveats |
|---|---|---|
| Crypto search, history, prices | [CoinGecko](https://www.coingecko.com/en/api) — `Folio.Clients.CoinGecko` | Keyless: ~5–15 req/min, history capped at ~365 days. A free demo key raises this to 100/min. |
| Stock and ETF search, history, prices | Yahoo Finance, unofficial — `Folio.Clients.Yahoo` | Keyless but needs a browser User-Agent (the client sends one). Search results carry no currency, so it is read from the chart endpoint's metadata. Unofficial, and the most likely to break; rate-limit responses are snoozed and retried. |
| FX rates (daily, EUR pivot) | [Frankfurter](https://frankfurter.dev) / ECB — `Folio.Clients.Frankfurter` | Keyless, business days only — weekend gaps are expected and resolved by "latest rate at or before" lookups. |

Stooq was considered for equities and rejected: it now sits behind a JavaScript
proof-of-work check and cannot be used server-side.

To swap a provider, implement `Folio.Clients.CryptoClient`,
`Folio.Clients.EquityClient` or `Folio.Clients.FxClient` and point the matching key
in `config :folio, :clients` (in `config/config.exs`) at your module.

## Development

```sh
mix test        # tests; creates and migrates the test database first
mix precommit   # compile --warnings-as-errors, unused deps, format, credo, test
mix ecto.reset  # drop, create, migrate, reseed
```

Tests stub the HTTP layer with `Req.Test` against recorded fixtures, so no test
ever touches the network.

## Built with

- **Phoenix 1.8** and **LiveView** on Bandit, backed by **PostgreSQL**, with
  **Oban** for background price and FX jobs.
- **Tailwind v4** and daisyUI — and **no npm**: there is no `package.json` and no
  `node_modules`. Assets are built by the `tailwind` and `esbuild` Mix tasks.
- Charts use TradingView's [lightweight-charts](https://github.com/tradingview/lightweight-charts)
  (Apache-2.0), vendored in `assets/vendor/`. Sparklines are server-rendered SVG.
- Every monetary value is a `Decimal` end to end — JSON is decoded with
  `floats: :decimals` so floating-point values never enter the system.

## License

MIT — see [LICENSE](LICENSE).
