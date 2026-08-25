# Dev sample data: a realistic portfolio (BTC, a EUR-quoted ETF, a USD stock)
# with two years of transactions and generated price/FX history, so the
# dashboard has data without touching external APIs. Idempotent: reruns are
# no-ops once the sample transactions exist.
#
#     mix run priv/repo/seeds.exs

defmodule Folio.DevSeeds do
  @moduledoc false

  alias Folio.Accounts
  alias Folio.Assets.Asset
  alias Folio.MarketData
  alias Folio.Portfolios
  alias Folio.Portfolios.Transaction
  alias Folio.Repo

  def run do
    admin = Accounts.ensure_admin(bootstrap_config(:admin_password, "admin"))
    portfolio = ensure_portfolio(admin.id)

    if Portfolios.list_transactions(portfolio.id) == [] do
      # Deterministic "randomness" so reseeding a reset DB gives the same data.
      :rand.seed(:exsss, {42, 42, 42})

      today = Date.utc_today()
      from = Date.add(today, -730)

      bitcoin = ensure_asset(bitcoin_attrs())
      etf = ensure_asset(etf_attrs())
      stock = ensure_asset(stock_attrs())

      seed_prices(bitcoin.id, from, today, 25_000_00, 40, all_days: true)
      seed_prices(etf.id, from, today, 85_00, 6, all_days: false)
      seed_prices(stock.id, from, today, 45_00, 10, all_days: false)
      seed_fx("USD", from, today)
      seed_intraday([bitcoin.id, etf.id, stock.id], today)

      seed_transactions(portfolio.id, bitcoin: bitcoin, etf: etf, stock: stock, from: from)

      IO.puts("Seeded sample portfolio ##{portfolio.id} with generated history.")
    else
      IO.puts("Sample data already present - nothing to do.")
    end
  end

  defp ensure_portfolio(admin_id) do
    case Portfolios.default_portfolio_for(admin_id) do
      nil ->
        {:ok, portfolio} =
          Portfolios.create_portfolio(%{name: "Portfolio", base_currency: "EUR"}, admin_id)

        portfolio

      portfolio ->
        portfolio
    end
  end

  # Direct inserts on purpose: `Assets.create_asset/1` would enqueue network
  # backfills, which seeds must not trigger.
  defp ensure_asset(attrs) do
    %Asset{}
    |> Asset.changeset(attrs)
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:price_source, :source_id])

    Repo.get_by!(Asset, price_source: attrs.price_source, source_id: attrs.source_id)
  end

  defp bitcoin_attrs do
    %{
      symbol: "BTC",
      name: "Bitcoin",
      kind: :crypto,
      quote_currency: "EUR",
      price_source: :coingecko,
      source_id: "bitcoin"
    }
  end

  defp etf_attrs do
    %{
      symbol: "EUNL.DE",
      name: "iShares Core MSCI World UCITS ETF",
      kind: :etf,
      exchange: "XETRA",
      quote_currency: "EUR",
      price_source: :yahoo,
      source_id: "EUNL.DE"
    }
  end

  defp stock_attrs do
    %{
      symbol: "NVDA",
      name: "NVIDIA Corporation",
      kind: :stock,
      exchange: "NasdaqGS",
      quote_currency: "USD",
      price_source: :yahoo,
      source_id: "NVDA"
    }
  end

  # Random walk in integer cents (no floats anywhere near prices).
  defp seed_prices(asset_id, from, to, start_cents, step_percent_permille, opts) do
    all_days = Keyword.fetch!(opts, :all_days)

    {entries, _cents} =
      from
      |> Date.range(to)
      |> Enum.reject(fn date -> not all_days and Date.day_of_week(date) in [6, 7] end)
      |> Enum.map_reduce(start_cents, fn date, cents ->
        drift = div(cents, 2000)
        swing = div(cents * step_percent_permille, 1000)
        cents = max(cents + drift + :rand.uniform(2 * swing + 1) - swing - 1, 100)
        {%{date: date, price: cents_to_decimal(cents)}, cents}
      end)

    :ok = MarketData.upsert_daily_prices(asset_id, entries)
  end

  defp seed_fx(currency, from, to) do
    {entries, _cents} =
      from
      |> Date.range(to)
      |> Enum.reject(fn date -> Date.day_of_week(date) in [6, 7] end)
      |> Enum.map_reduce(10_800, fn date, fraction ->
        fraction = max(fraction + :rand.uniform(61) - 31, 9000)
        {%{date: date, rate: Decimal.div(Decimal.new(fraction), 10_000)}, fraction}
      end)

    :ok = MarketData.upsert_fx_rates(currency, entries)
  end

  # Recent ticks so the 1d/1w windows have intraday resolution: hourly points
  # for the retention window, jittering around the daily close.
  defp seed_intraday(asset_ids, today) do
    for asset_id <- asset_ids do
      closes =
        Map.new(
          MarketData.daily_prices(asset_id, from: Date.add(today, -9)),
          &{&1.date, &1.price}
        )

      entries =
        for day_offset <- -7..0,
            date = Date.add(today, day_offset),
            close = closes[date] || closes[Date.add(date, -1)] || closes[Date.add(date, -2)],
            hour <- 0..23,
            at = DateTime.new!(date, Time.new!(hour, 0, 0), "Etc/UTC"),
            DateTime.compare(at, DateTime.utc_now()) != :gt do
          jitter = Decimal.div(Decimal.new(:rand.uniform(41) - 21), 1000)
          %{at: at, price: Decimal.mult(close, Decimal.add(1, jitter))}
        end

      :ok = MarketData.upsert_intraday_prices(asset_id, entries)
    end
  end

  # A savings-plan style history: monthly ETF buys, quarterly BTC buys, a few
  # NVDA trades including a partial sell. Direct inserts skip backfill jobs;
  # source/external_id make reruns conflict instead of duplicating.
  defp seed_transactions(portfolio_id, opts) do
    bitcoin = Keyword.fetch!(opts, :bitcoin)
    etf = Keyword.fetch!(opts, :etf)
    stock = Keyword.fetch!(opts, :stock)
    from = Keyword.fetch!(opts, :from)

    monthly = for offset <- 0..23, do: Date.add(from, offset * 30 + 3)
    quarterly = Enum.take_every(monthly, 3)

    etf_txns =
      for {date, index} <- Enum.with_index(monthly) do
        txn(etf, :buy, date, "1.5", price_on(etf.id, date), "1", "etf-#{index}")
      end

    btc_txns =
      for {date, index} <- Enum.with_index(quarterly) do
        txn(bitcoin, :buy, date, "0.01", price_on(bitcoin.id, date), "2", "btc-#{index}")
      end

    stock_txns = [
      txn(
        stock,
        :buy,
        Date.add(from, 60),
        "10",
        price_on(stock.id, Date.add(from, 60)),
        "1",
        "nvda-0"
      ),
      txn(
        stock,
        :buy,
        Date.add(from, 400),
        "5",
        price_on(stock.id, Date.add(from, 400)),
        "1",
        "nvda-1"
      ),
      txn(
        stock,
        :sell,
        Date.add(from, 650),
        "4",
        price_on(stock.id, Date.add(from, 650)),
        "1",
        "nvda-2"
      )
    ]

    for {asset, type, date, quantity, price, fee, external_id} <-
          etf_txns ++ btc_txns ++ stock_txns do
      Repo.insert!(
        %Transaction{
          portfolio_id: portfolio_id,
          asset_id: asset.id,
          type: type,
          executed_at: DateTime.new!(date, ~T[14:30:00], "Etc/UTC"),
          quantity: Decimal.new(quantity),
          price_per_unit: price,
          fee: Decimal.new(fee),
          currency: asset.quote_currency,
          source: "seed",
          external_id: external_id
        },
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment,
           "(source, external_id) WHERE source IS NOT NULL AND external_id IS NOT NULL"}
      )
    end
  end

  defp txn(asset, type, date, quantity, price, fee, external_id) do
    {asset, type, date, quantity, price, fee, external_id}
  end

  # The latest close at or before the date - mirrors the engine's lookup.
  defp price_on(asset_id, date) do
    asset_id
    |> MarketData.daily_prices()
    |> Enum.reverse()
    |> Enum.find_value(fn %{date: close_date, price: price} ->
      if Date.compare(close_date, date) != :gt, do: price
    end)
  end

  defp cents_to_decimal(cents), do: Decimal.div(Decimal.new(cents), 100)

  defp bootstrap_config(key, default) do
    :folio |> Application.get_env(Folio.Bootstrap, []) |> Keyword.get(key, default)
  end
end

Folio.DevSeeds.run()
