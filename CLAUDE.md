# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Required reading

Both files below are authoritative. Do not restate or duplicate their rules here —
this file only covers what they don't.

@AGENTS.md

Elixir, Phoenix v1.8, LiveView, Ecto and HEEx rules: template/layout conventions,
LiveView streams, JS interop and hooks, form handling, test guidelines.

@CODING_GUIDE.md

Elixir style for this project: module member ordering, `@spec`/`@doc` on public
functions, atom-keyed internal maps, minimal public-function parameters, pattern
matching in function heads, cross-domain decoupling, and reading env vars only in
`config/runtime.exs`.

## Project

`folio` is a Phoenix 1.8 web application on Elixir 1.20.3 / OTP 28 (see `.tool-versions`),
served by Bandit and backed by PostgreSQL through `Folio.Repo`.

- `Folio` — domain and business logic (contexts).
- `FolioWeb` — web layer.

It is a single-portfolio investment tracker: manually entered buy/sell transactions for
crypto, stocks and ETFs, with prices and FX rates fetched in the background and a
dashboard showing value/profit over time and per-asset holdings.

Contexts: `Accounts` (one bootstrapped Admin, no login flow), `Portfolios` (portfolios,
members, transactions), `Assets` (shared instruments + resolver), `MarketData` (daily
closes, intraday ticks, FX rates, Oban workers), `Analytics` (the read side — series,
summaries, holdings). Plus `Bootstrap` (idempotent boot-time setup) and `Release`.

The web layer is a single `FolioWeb.DashboardLive`; all four routes (`/`,
`/assets/:asset_id`, `/transactions/new`, `/transactions/:id/edit`) are live actions on
it, so window/mode/currency selections survive navigation.

## Commands

    mix setup                       # deps, DB create+migrate+seed, asset install+build
    mix phx.server                  # dev server on http://localhost:4000
    iex -S mix phx.server           # same, with a shell attached
    mix test                        # alias also creates + migrates the test DB first
    mix test test/path/file.exs:42  # single test by line
    mix format
    mix credo
    mix ecto.reset                  # drop, create, migrate, seed
    mix assets.build                # compile + tailwind + esbuild

**`mix precommit` is the finishing gate.** Run it when a change is complete and fix
everything it reports. It runs compile with warnings-as-errors → unused-dep check →
format → credo → test, all under `MIX_ENV=test`.

## Database

    docker compose up -d postgresql

Starts Postgres 16 on `:5432` with the credentials `config/dev.exs` and `config/test.exs`
already expect (`postgres` / `postgres`). Data persists in `.docker/postgres`.

## Architecture

- `lib/folio/` — contexts and domain logic: `accounts/`, `portfolios/`, `assets/`,
  `market_data/` (with `workers/` for the Oban jobs), `analytics/`, plus `clients/`
  (behaviour-backed market data providers), `application.ex`, `bootstrap.ex`, `repo.ex`.
- `lib/folio_web/` — `router.ex`, `endpoint.ex`, `user_auth.ex`, `live/dashboard_live.ex`,
  `controllers/`, `components/` (`core_components.ex`, `layouts.ex`).
- `lib/folio_web.ex` — the `use FolioWeb, :controller | :html | :live_view | ...` entrypoint.
- `config/` — `config.exs` (shared) → `dev|test|prod.exs`, then `runtime.exs`.
  `runtime.exs` is the only place environment variables are read.
- `priv/repo/migrations/` — migrations. `priv/static/` — served assets.
- `assets/css/app.css`, `assets/js/app.js` — the only two bundles.
- `test/support/` — `ConnCase` and `DataCase` (Ecto SQL Sandbox).

## Project-specific notes

- **Tailwind is v4**: all configuration lives in `assets/css/app.css`. There is no
  `tailwind.config.js`.
- **No npm.** heroicons and daisyUI are git dependencies declared in `mix.exs`; there is no
  `package.json` or `node_modules`. Vendored JS lives in `assets/vendor/`.
- **Dev-only routes**, gated on `config :folio, dev_routes: true`: `/dev/dashboard`
  (LiveDashboard) and `/dev/mailbox` (Swoosh local adapter preview).
- **HTTP client is `Req`.** It is already a dependency.
- Generators default to `timestamp_type: :utc_datetime` (`config/config.exs`).
