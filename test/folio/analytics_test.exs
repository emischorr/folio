defmodule Folio.AnalyticsTest do
  use Folio.DataCase, async: true

  import Folio.AssetsFixtures
  import Folio.MarketDataFixtures
  import Folio.PortfoliosFixtures

  alias Folio.Analytics

  @now ~U[2025-01-10 12:00:00Z]

  # A EUR portfolio holding BTC (EUR-quoted, bought 2025-01-06) and NVDA
  # (USD-quoted, bought 2025-01-08). Daily closes and weekday FX seeded for
  # 2025-01-06 (Mon) .. 2025-01-10 (Fri).
  defp seeded_portfolio do
    portfolio = portfolio_fixture()
    bitcoin = crypto_asset_fixture()
    stock = stock_asset_fixture()

    seed_daily_prices(bitcoin.id, ~D[2025-01-06], ~D[2025-01-10], "100", "10")
    seed_daily_prices(stock.id, ~D[2025-01-06], ~D[2025-01-10], "50", "0")
    seed_fx_rates("USD", ~D[2025-01-06], ~D[2025-01-10], "1.25", "0")

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2025-01-06 10:00:00Z],
      quantity: "2",
      price_per_unit: "100"
    })

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: stock.id,
      executed_at: ~U[2025-01-08 10:00:00Z],
      quantity: "5",
      price_per_unit: "50",
      currency: "USD"
    })

    %{portfolio: portfolio, bitcoin: bitcoin, stock: stock}
  end

  test "value_series spans the max window and converts USD holdings per timestamp" do
    %{portfolio: portfolio} = seeded_portfolio()

    series = Analytics.value_series(portfolio.id, :max, "EUR", now: @now)

    assert length(series) == 5
    assert Enum.map(series, & &1.at) |> List.first() == ~U[2025-01-06 00:00:00Z]

    # 2025-01-07: only BTC held: 2 x 110 = 220.
    assert Decimal.eq?(Enum.at(series, 1).value, "220")
    # 2025-01-10: 2 x 140 + 5 x 50 USD / 1.25 = 280 + 200 = 480.
    assert Decimal.eq?(Enum.at(series, 4).value, "480")
  end

  test "profit_series subtracts cost basis with the USD buy locked at execution" do
    %{portfolio: portfolio} = seeded_portfolio()

    series = Analytics.profit_series(portfolio.id, :max, "EUR", now: @now)

    # Cost basis: 200 EUR + (250 USD / 1.25 = 200 EUR) = 400.
    # 2025-01-10 value 480 => profit 80.
    assert Decimal.eq?(List.last(series).value, "80")
  end

  test "summary subtracts the mid-window cashflow from the change" do
    %{portfolio: portfolio} = seeded_portfolio()

    summary = Analytics.summary(portfolio.id, :max, "EUR", now: @now)

    # value_start (01-06) = 200; value_now = 480; net cashflow inside = 200.
    assert Decimal.eq?(summary.value, "480")
    assert Decimal.eq?(summary.change_abs, "80")
    assert Decimal.eq?(summary.change_pct, "20")
  end

  test "the display currency converts value and change per timestamp" do
    %{portfolio: portfolio} = seeded_portfolio()

    summary = Analytics.summary(portfolio.id, :max, "USD", now: @now)
    assert Decimal.eq?(summary.value, "600")
  end

  test "single-asset scope narrows series and summary" do
    %{portfolio: portfolio, bitcoin: bitcoin} = seeded_portfolio()

    series = Analytics.value_series(portfolio.id, :max, "EUR", now: @now, asset_id: bitcoin.id)
    assert Decimal.eq?(List.last(series).value, "280")
  end

  test "holdings lists quantity, value, window change, and sparkline series per asset" do
    %{portfolio: portfolio, bitcoin: bitcoin, stock: stock} = seeded_portfolio()

    holdings = Analytics.holdings(portfolio.id, :max, "EUR", now: @now)

    assert [first, second] = holdings
    assert first.asset_id == bitcoin.id
    assert first.kind == :crypto
    assert Decimal.eq?(first.quantity, "2")
    assert Decimal.eq?(first.value, "280")
    assert Decimal.eq?(first.change_abs, "80")
    assert Decimal.eq?(first.change_pct, "40")
    assert first.has_data?
    assert length(first.series) == 5
    assert Decimal.eq?(List.last(first.series).value, "280")

    assert second.asset_id == stock.id
    assert Decimal.eq?(second.value, "200")
    assert Decimal.eq?(second.change_abs, "0")
    assert Decimal.eq?(second.change_pct, "0")
  end

  test "holdings marks assets without stored prices and omits sold-out positions" do
    %{portfolio: portfolio, bitcoin: bitcoin} = seeded_portfolio()
    etf = etf_asset_fixture()

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: etf.id,
      executed_at: ~U[2025-01-09 10:00:00Z],
      quantity: "1",
      price_per_unit: "10"
    })

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      type: :sell,
      executed_at: ~U[2025-01-09 11:00:00Z],
      quantity: "2",
      price_per_unit: "130"
    })

    holdings = Analytics.holdings(portfolio.id, :max, "EUR", now: @now)

    refute Enum.any?(holdings, &(&1.asset_id == bitcoin.id))
    assert %{has_data?: false, value: value} = Enum.find(holdings, &(&1.asset_id == etf.id))
    assert Decimal.eq?(value, "0")
  end

  test "asset_position compares current value/price to the FIFO buy lots" do
    %{portfolio: portfolio, bitcoin: bitcoin, stock: stock} = seeded_portfolio()

    btc_position = Analytics.asset_position(portfolio.id, bitcoin.id, "EUR", "EUR", now: @now)
    assert Decimal.eq?(btc_position.quantity, "2")
    assert Decimal.eq?(btc_position.quantity_change_12m, "2")
    assert Decimal.eq?(btc_position.value_now, "280")
    assert Decimal.eq?(btc_position.value_buy, "200")
    assert Decimal.eq?(btc_position.price_now, "140")
    assert Decimal.eq?(btc_position.price_buy, "100")
    assert Decimal.eq?(btc_position.profit_abs, "80")
    assert Decimal.eq?(btc_position.profit_pct, "40")

    # NVDA: 5 @ 50 USD bought, flat at 50 USD now -> no profit, but the
    # display currency still converts both legs at the same (flat) FX rate.
    stock_position = Analytics.asset_position(portfolio.id, stock.id, "USD", "EUR", now: @now)
    assert Decimal.eq?(stock_position.value_now, "200")
    assert Decimal.eq?(stock_position.value_buy, "200")
    assert Decimal.eq?(stock_position.profit_abs, "0")
    assert Decimal.eq?(stock_position.profit_pct, "0")
  end

  test "asset_position carries the remaining lot's own buy price after a partial sell" do
    portfolio = portfolio_fixture()
    bitcoin = crypto_asset_fixture()
    seed_daily_prices(bitcoin.id, ~D[2025-01-06], ~D[2025-01-10], "100", "10")

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2025-01-06 10:00:00Z],
      quantity: "2",
      price_per_unit: "100"
    })

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2025-01-08 10:00:00Z],
      quantity: "1",
      price_per_unit: "130"
    })

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      type: :sell,
      executed_at: ~U[2025-01-09 10:00:00Z],
      quantity: "2",
      price_per_unit: "135"
    })

    position = Analytics.asset_position(portfolio.id, bitcoin.id, "EUR", "EUR", now: @now)

    # The sell drains the whole first lot (2 @ 100) then leaves the second
    # lot (1 @ 130) untouched, so the average buy price stays 130, not the
    # blended 110.
    assert Decimal.eq?(position.quantity, "1")
    assert Decimal.eq?(position.price_buy, "130")
    assert Decimal.eq?(position.value_buy, "130")
    assert Decimal.eq?(position.price_now, "140")
  end

  test "asset_position's quantity_change_12m only counts transactions inside the trailing 365 days" do
    portfolio = portfolio_fixture()
    bitcoin = crypto_asset_fixture()
    seed_daily_prices(bitcoin.id, ~D[2025-01-06], ~D[2025-01-10], "100", "10")

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2023-01-01 10:00:00Z],
      quantity: "2",
      price_per_unit: "100"
    })

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2024-06-01 10:00:00Z],
      quantity: "1",
      price_per_unit: "100"
    })

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      type: :sell,
      executed_at: ~U[2024-12-01 10:00:00Z],
      quantity: "1",
      price_per_unit: "100"
    })

    position = Analytics.asset_position(portfolio.id, bitcoin.id, "EUR", "EUR", now: @now)

    assert Decimal.eq?(position.quantity, "2")
    assert Decimal.eq?(position.quantity_change_12m, "0")
  end

  test "asset_position is nil once the position is fully sold" do
    %{portfolio: portfolio, bitcoin: bitcoin} = seeded_portfolio()

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      type: :sell,
      executed_at: ~U[2025-01-09 10:00:00Z],
      quantity: "2",
      price_per_unit: "130"
    })

    assert Analytics.asset_position(portfolio.id, bitcoin.id, "EUR", "EUR", now: @now) == nil
  end

  test "asset_position is nil when there is no current price" do
    portfolio = portfolio_fixture()
    bitcoin = crypto_asset_fixture()

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2025-01-06 10:00:00Z],
      quantity: "2",
      price_per_unit: "100"
    })

    assert Analytics.asset_position(portfolio.id, bitcoin.id, "EUR", "EUR", now: @now) == nil
  end

  test "convert translates via stored FX rates and passes same-currency through" do
    seed_fx_rates("USD", ~D[2025-01-06], ~D[2025-01-10], "1.25", "0")

    assert Decimal.eq?(Analytics.convert(Decimal.new("100"), "EUR", "EUR", @now), "100")
    assert Decimal.eq?(Analytics.convert(Decimal.new("125"), "USD", "EUR", @now), "100")
    assert Analytics.convert(Decimal.new(1), "USD", "CHF", @now) == nil
  end

  test "an empty portfolio yields empty series and a zero summary" do
    portfolio = portfolio_fixture()

    assert Analytics.value_series(portfolio.id, :max, "EUR", now: @now) == []
    summary = Analytics.summary(portfolio.id, :max, "EUR", now: @now)
    assert Decimal.eq?(summary.value, "0")
    assert summary.change_pct == nil
  end

  test "intraday windows blend daily closes with recent ticks" do
    portfolio = portfolio_fixture()
    bitcoin = crypto_asset_fixture()
    seed_daily_prices(bitcoin.id, ~D[2025-01-06], ~D[2025-01-09], "100", "10")
    seed_intraday_prices(bitcoin.id, ~U[2025-01-10 09:00:00Z], ~U[2025-01-10 09:00:00Z], "150")

    transaction_fixture(%{
      portfolio_id: portfolio.id,
      asset_id: bitcoin.id,
      executed_at: ~U[2025-01-06 10:00:00Z],
      quantity: "1",
      price_per_unit: "100"
    })

    series = Analytics.value_series(portfolio.id, :"1d", "EUR", now: @now)

    # Before the 09:00 tick the latest daily close (130) applies; after it, 150.
    early = Enum.find(series, &(DateTime.compare(&1.at, ~U[2025-01-10 08:00:00Z]) == :eq))
    assert Decimal.eq?(early.value, "130")
    assert Decimal.eq?(List.last(series).value, "150")
  end
end
