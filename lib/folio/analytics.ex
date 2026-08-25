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

    case grid do
      [] ->
        %{value: value_now, change_abs: @zero, change_pct: nil}

      [window_start | _rest] ->
        value_start = Engine.value_at(dataset, window_start, display_currency)
        net_cashflow = Engine.net_cashflow(dataset, window_start, now, display_currency)
        change_abs = value_now |> Decimal.sub(value_start) |> Decimal.sub(net_cashflow)

        %{
          value: value_now,
          change_abs: change_abs,
          change_pct: percentage(change_abs, Decimal.add(value_start, net_cashflow))
        }
    end
  end

  @doc """
  Current holdings per asset: quantity, current value, and overall profit
  (absolute and percentage vs cost basis), in the display currency. Assets
  with zero quantity and zero cost basis are omitted; sorted by value,
  largest first.
  """
  @spec holdings(pos_integer(), String.t(), keyword()) :: [map()]
  def holdings(portfolio_id, display_currency, opts \\ []) do
    {dataset, _grid, now} = prepare(portfolio_id, :max, display_currency, opts)
    quantities = Engine.holdings_at(dataset, now)

    dataset.assets
    |> Enum.map(fn {asset_id, %{symbol: symbol, name: name}} ->
      scoped = Dataset.scope_to_asset(dataset, asset_id)
      quantity = Map.get(quantities, asset_id, @zero)
      value = Engine.value_at(scoped, now, display_currency)
      cost_basis = Engine.cost_basis_at(scoped, now, display_currency)
      profit_abs = Decimal.sub(value, cost_basis)

      %{
        asset_id: asset_id,
        symbol: symbol,
        name: name,
        quantity: quantity,
        value: value,
        profit_abs: profit_abs,
        profit_pct: percentage(profit_abs, cost_basis)
      }
    end)
    |> Enum.reject(&(Decimal.eq?(&1.quantity, @zero) and Decimal.eq?(&1.value, @zero)))
    |> Enum.sort_by(& &1.value, {:desc, Decimal})
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
    %{symbol: symbol, name: name, quote_currency: quote_currency} = Assets.get_asset!(asset_id)
    %{symbol: symbol, name: name, quote_currency: quote_currency}
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
    |> Map.new(fn currency ->
      series =
        for %{date: date, rate: rate} <- MarketData.fx_rates(currency), do: {midnight(date), rate}

      {currency, Enum.sort_by(series, &elem(&1, 0), {:desc, DateTime})}
    end)
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
