# Folio

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## External data sources

Prices and FX rates are fetched in the background (Oban). Every provider sits
behind a behaviour, so swapping one means implementing the behaviour and
changing one line in `config :folio, :clients`.

| Data | Provider | Endpoint | Limits / caveats |
|---|---|---|---|
| Crypto search, history, current prices | [CoinGecko](https://www.coingecko.com/en/api) (`Folio.Clients.CoinGecko`) | `api.coingecko.com/api/v3` | Keyless: ~5-15 requests/min and history capped at ~365 days. A free demo key via the `COINGECKO_API_KEY` env var raises the limit to 100/min, 10k/month. |
| Stock/ETF search, history, current prices | Yahoo Finance, unofficial (`Folio.Clients.Yahoo`) | `query1.finance.yahoo.com` | Keyless but requires a browser User-Agent (the client sends one). Search results carry **no currency** - it is read from the chart endpoint's metadata. Unofficial and the most likely to break; occasional 429/999 responses are snoozed and retried. |
| FX rates (daily, EUR pivot) | [Frankfurter](https://frankfurter.dev) / ECB (`Folio.Clients.Frankfurter`) | `api.frankfurter.dev/v1` | Keyless, business days only - weekend gaps are expected and handled by "latest at or before" lookups. |

Stooq was considered for equities but rejected: it now sits behind a
JavaScript proof-of-work check and cannot be used server-side.

To swap a provider, implement `Folio.Clients.CryptoClient`,
`Folio.Clients.EquityClient`, or `Folio.Clients.FxClient` and point the
matching key in `config :folio, :clients` (in `config/config.exs`) at your
module. Tests stub the HTTP layer with `Req.Test`, so no test touches the
network.

## Dev data

`mix ecto.setup` (and `mix ecto.reset`) seed a sample portfolio - BTC, a
EUR-quoted ETF, and NVDA in USD - with two years of transactions and locally
generated price/FX history, so nothing hits the external APIs.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
