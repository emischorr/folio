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
- **Yahoo search is the scarcest resource in this project.**
  `query{1,2}.finance.yahoo.com/v1/finance/search` is rate-limited per IP and answers
  429 far sooner than you would expect - roughly 50 requests across an afternoon
  earned a throttle that had not lifted two hours later, on both hosts. **`/v8/finance/chart`
  is not a safe harbour**: it has its own bucket and OpenFIGI has another, but the chart
  endpoint has been observed answering 429 too, with the browser User-Agent the client
  sends - so a throttle can stop prices updating, not just search. **Never probe either
  endpoint in a loop, and never poll to see whether a throttle has cleared.** Develop against the recorded fixtures in
  `test/support/api_responses/` and spend live calls only on one final check.
  `Folio.Assets.SearchCache` sits in front of every resolution lookup - 10 minutes
  for hits, a 60-second negative cache for 429s - and `mix precommit` never touches
  the network. `Folio.Clients.HTTP.retry?/2` also refuses to retry a 429: Req's
  built-in `:transient` policy turns one throttled lookup into three requests. On the
  job side, `Folio.MarketData.Backoff` caps how often a rate-limited worker may snooze
  and then cancels it - an uncapped snooze keeps a throttled endpoint under load
  forever, because Oban raises `max_attempts` on every snooze.
- Generators default to `timestamp_type: :utc_datetime` (`config/config.exs`).

## CodeLead preview contract

This repository is developed with CodeLead. Tasks run in a git worktree and
the Review tab previews this app's dev server, so a few things have to keep
working. Check them before touching dev config, the server entrypoint, or how
URLs and assets are emitted.

CodeLead exports three variables into the preview command and into every
terminal session. All three are absent in ordinary local dev, so each rule
below must be a no-op when they are unset:

- `PREVIEW_PORT` — the port to listen on. **Bind it; never hardcode a port.**
  Already wired: `config/runtime.exs` reads `PORT || PREVIEW_PORT || 4000`, so
  the preview command is a bare `mix phx.server` with no `PORT=` prefix.
- `PREVIEW_BASE_PATH` — the path prefix this app is served under, e.g.
  `/preview/42`, with **no trailing slash**; empty when the app owns its own
  origin. **Honor it:** set `url: [path: System.get_env("PREVIEW_BASE_PATH", "/")]` on the endpoint in `config/dev.exs`.
- `PREVIEW_ORIGIN` — the browser-facing origin the preview is reached at.

The rest holds whether or not those variables are set:

- **Bind `0.0.0.0`, not `127.0.0.1`.** When the task runs in a container the
  preview reaches this app over the container network, and a socket bound to
  the container's own loopback is invisible to it. Already wired: the endpoint
  in `config/dev.exs` binds every interface when `DEVCONTAINER` is set, which
  `.devcontainer/compose.yml` does; local dev stays on loopback.

- **The LiveSocket path is rendered, never hardcoded.** `root.html.heex` emits
  `FolioWeb.Endpoint.path("/live")` into a `live-socket-path` meta tag and
  `assets/js/app.js` reads it. Do not put a literal `"/live"` back into
  `new LiveSocket(...)` — under a path preview that opens against CodeLead's own
  LiveView endpoint, which rejects the join, and the page reloads itself forever.

- **Never write a root-absolute URL by hand.** The preview proxy never
  rewrites response bodies, so `href="/"`, `src="/assets/…"`, `url("/fonts/…")`
  in CSS, `fetch("/api/…")` and hardcoded websocket paths escape the prefix and
  hit CodeLead instead of this app. Use the router's own path helper; make CSS
  urls relative to where the *bundle* lands. A hardcoded socket path is the
  worst case — it makes the preview reload itself in a loop.

- **The dev server must be a single process.** Dependency installs, database
  setup and seeds belong in `.devcontainer` lifecycle hooks
  (`postCreateCommand` / `postStartCommand`), never chained onto the start
  command with `&&`.

- **Keep toolchain state out of `$HOME`.** CodeLead overrides `HOME` per task,
  so anything installed under `~` (nvm, rustup, pyenv, cargo, hex) is invisible
  to agents — point those at `/opt/…` in the devcontainer image instead. Build
  output belongs off the shared workspace mount for the same class of reason.
  Already wired: `.devcontainer/Dockerfile` sets `MIX_HOME`/`HEX_HOME` and
  `MIX_BUILD_ROOT` under `/opt`, and runs as the non-root `dev` user.

- **The Repo host comes from `PGHOST`** (`config/dev.exs`, `config/test.exs`),
  defaulting to `localhost`. `.devcontainer/compose.yml` points it at the
  sibling `db` service; the root `docker-compose.yml` remains the local path.