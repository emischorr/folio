defmodule Folio.Analytics do
  @moduledoc """
  The read side of the dashboard: value/profit series, window summaries, and
  per-asset holdings, all derived from transactions plus stored price/FX
  history. Loads the relevant rows once per call into a plain-data
  `Folio.Analytics.Dataset` and delegates the math to the pure
  `Folio.Analytics.Engine`.

  The display currency is a view parameter converted per timestamp; the
  portfolio's `base_currency` is what cost basis is tracked in.

  Options accepted by all functions: `:asset_id` scopes to a single asset,
  `:now` injects the current time (tests).
  """

  alias Folio.Analytics.Dataset
  alias Folio.Analytics.Engine
  alias Folio.Analytics.Grid
  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.Portfolios

  @zero Decimal.new(0)
  @intraday_windows [:"1d", :"1w"]

  @type holding :: %{
          asset_id: pos_integer(),
          symbol: String.t(),
          name: String.t(),
          kind: Assets.Asset.kind(),
          quantity: Decimal.t(),
          value: Decimal.t(),
          change_abs: Decimal.t(),
          change_pct: Decimal.t() | nil,
          series: [%{at: DateTime.t(), value: Decimal.t()}],
          has_data?: boolean()
        }

  @doc "Value at each grid point of the window, in the display currency."
  @spec value_series(pos_integer(), Grid.window(), String.t(), keyword()) ::
          [%{at: DateTime.t(), value: Decimal.t()}]
  def value_series(portfolio_id, window, display_currency, opts \\ []) do
    {dataset, grid, _now} = prepare(portfolio_id, window, display_currency, opts)
    Engine.value_series(dataset, grid, display_currency)
  end

  @doc "Profit (value minus cost basis) at each grid point, in the display currency."
  @spec profit_series(pos_integer(), Grid.window(), String.t(), keyword()) ::
          [%{at: DateTime.t(), value: Decimal.t()}]
  def profit_series(portfolio_id, window, display_currency, opts \\ []) do
    {dataset, grid, _now} = prepare(portfolio_id, window, display_currency, opts)
    Engine.profit_series(dataset, grid, display_currency)
  end

  @doc """
  Current value plus the change over the window, as an absolute amount and a
  percentage (of capital at risk at window start). Net cashflow inside the
  window is subtracted, so a deposit is not reported as profit. The
  percentage is nil when there was no positive capital at risk.
  """
  @spec summary(pos_integer(), Grid.window(), String.t(), keyword()) ::
          %{value: Decimal.t(), change_abs: Decimal.t(), change_pct: Decimal.t() | nil}
  def summary(portfolio_id, window, display_currency, opts \\ []) do
    {dataset, grid, now} = prepare(portfolio_id, window, display_currency, opts)
    value_now = Engine.value_at(dataset, now, display_currency)

    dataset
    |> window_change(grid, value_now, now, display_currency)
    |> Map.put(:value, value_now)
  end

  @doc """
  Current holdings per asset with the change over the window and the value
  series for the same window (sparklines), in the display currency. Assets
  with zero quantity and zero value are omitted; sorted by value, largest
  first. `has_data?` is false while an asset has no stored prices yet
  (backfill pending) - its value contributions are zero until data arrives.
  """
  @spec holdings(pos_integer(), Grid.window(), String.t(), keyword()) :: [holding()]
  def holdings(portfolio_id, window, display_currency, opts \\ []) do
    {dataset, grid, now} = prepare(portfolio_id, window, display_currency, opts)
    quantities = Engine.holdings_at(dataset, now)

    dataset.assets
    |> Enum.map(fn {asset_id, %{symbol: symbol, name: name, kind: kind}} ->
      scoped = Dataset.scope_to_asset(dataset, asset_id)
      value = Engine.value_at(scoped, now, display_currency)

      %{
        asset_id: asset_id,
        symbol: symbol,
        name: name,
        kind: kind,
        quantity: Map.get(quantities, asset_id, @zero),
        value: value,
        series: Engine.value_series(scoped, grid, display_currency),
        has_data?: Map.get(dataset.prices, asset_id, []) != []
      }
      |> Map.merge(window_change(scoped, grid, value, now, display_currency))
    end)
    |> Enum.reject(&(Decimal.eq?(&1.quantity, @zero) and Decimal.eq?(&1.value, @zero)))
    |> Enum.sort_by(& &1.value, {:desc, Decimal})
  end

  @doc """
  Converts an amount between currencies using stored EUR-pivot FX rates at
  `at`. Nil when a needed rate is entirely unknown.
  """
  @spec convert(Decimal.t(), String.t(), String.t(), DateTime.t()) :: Decimal.t() | nil
  def convert(amount, from_currency, to_currency, at \\ DateTime.utc_now())

  def convert(amount, currency, currency, _at), do: amount

  def convert(amount, from_currency, to_currency, at) do
    fx =
      [from_currency, to_currency]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "EUR"))
      |> Map.new(&{&1, currency_rates(&1)})

    Engine.convert(amount, from_currency, to_currency, fx, at)
  end

  defp window_change(_dataset, [], _value_now, _now, _display_currency) do
    %{change_abs: @zero, change_pct: nil}
  end

  defp window_change(dataset, [window_start | _rest], value_now, now, display_currency) do
    value_start = Engine.value_at(dataset, window_start, display_currency)
    net_cashflow = Engine.net_cashflow(dataset, window_start, now, display_currency)
    change_abs = value_now |> Decimal.sub(value_start) |> Decimal.sub(net_cashflow)

    %{
      change_abs: change_abs,
      change_pct: percentage(change_abs, Decimal.add(value_start, net_cashflow))
    }
  end

  defp prepare(portfolio_id, window, display_currency, opts) do
    portfolio = Portfolios.get_portfolio!(portfolio_id)
    txns = Portfolios.list_transactions(portfolio_id, asset_id: opts[:asset_id])
    now = Keyword.get(opts, :now, DateTime.utc_now())
    earliest = earliest_date(txns)
    grid = Grid.timestamps(window, now, earliest)
    dataset = load_dataset(portfolio, txns, window, List.first(grid) || now, display_currency)

    {dataset, grid, now}
  end

  defp load_dataset(portfolio, txns, window, window_start, display_currency) do
    assets = txns |> Enum.map(& &1.asset_id) |> Enum.uniq() |> Map.new(&{&1, asset_entry(&1)})

    %Dataset{
      base_currency: portfolio.base_currency,
      assets: assets,
      txns: Enum.map(txns, &txn_entry/1),
      prices:
        Map.new(assets, fn {asset_id, _entry} ->
          {asset_id, price_series(asset_id, window, window_start)}
        end),
      fx: fx_series(assets, txns, portfolio.base_currency, display_currency)
    }
  end

  defp asset_entry(asset_id) do
    %{symbol: symbol, name: name, kind: kind, quote_currency: quote_currency} =
      Assets.get_asset!(asset_id)

    %{symbol: symbol, name: name, kind: kind, quote_currency: quote_currency}
  end

  defp txn_entry(txn) do
    %{
      asset_id: txn.asset_id,
      type: txn.type,
      executed_at: txn.executed_at,
      quantity: txn.quantity,
      price_per_unit: txn.price_per_unit,
      fee: txn.fee,
      currency: txn.currency
    }
  end

  # Daily closes cover every window; intraday windows also merge in the raw
  # ticks near the window so 15-minute/hourly points move between closes.
  defp price_series(asset_id, window, window_start) do
    daily =
      for %{date: date, price: price} <- MarketData.daily_prices(asset_id) do
        {midnight(date), price}
      end

    intraday =
      if window in @intraday_windows do
        from = DateTime.add(window_start, -1, :day)

        for %{at: at, price: price} <- MarketData.intraday_prices(asset_id, from: from),
            do: {at, price}
      else
        []
      end

    Enum.sort_by(daily ++ intraday, &elem(&1, 0), {:desc, DateTime})
  end

  defp fx_series(assets, txns, base_currency, display_currency) do
    quote_currencies = for {_id, %{quote_currency: currency}} <- assets, do: currency
    txn_currencies = Enum.map(txns, & &1.currency)

    (quote_currencies ++ txn_currencies ++ [base_currency, display_currency])
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "EUR"))
    |> Map.new(&{&1, currency_rates(&1)})
  end

  defp currency_rates(currency) do
    series =
      for %{date: date, rate: rate} <- MarketData.fx_rates(currency), do: {midnight(date), rate}

    Enum.sort_by(series, &elem(&1, 0), {:desc, DateTime})
  end

  defp earliest_date([]), do: nil
  defp earliest_date([%{executed_at: executed_at} | _rest]), do: DateTime.to_date(executed_at)

  defp percentage(numerator, denominator) do
    if Decimal.compare(denominator, @zero) == :gt do
      numerator |> Decimal.div(denominator) |> Decimal.mult(100)
    end
  end

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
