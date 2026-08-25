defmodule Folio.Analytics.Engine do
  @moduledoc """
  Pure portfolio math over a `Folio.Analytics.Dataset`. Everything derives
  from two primitives: holdings (cumulative signed quantity at t) and
  at-or-before price/FX lookups, so weekends and missing ticks need no
  special handling.

  Cost-basis semantics: each transaction's cashflow is locked into the
  portfolio's base currency at execution time; only the base-to-display leg
  floats with the FX rate at each sampled timestamp. A missing price or FX
  rate makes that contribution zero rather than failing - backfills converge
  the numbers.
  """

  alias Folio.Analytics.Dataset
  alias Folio.Analytics.Lookup

  @zero Decimal.new(0)

  @doc "Portfolio value at each grid timestamp, in the display currency."
  @spec value_series(Dataset.t(), [DateTime.t()], String.t()) ::
          [%{at: DateTime.t(), value: Decimal.t()}]
  def value_series(dataset, grid, display_currency) do
    for t <- grid, do: %{at: t, value: value_at(dataset, t, display_currency)}
  end

  @doc "Profit (value minus cost basis) at each grid timestamp, in the display currency."
  @spec profit_series(Dataset.t(), [DateTime.t()], String.t()) ::
          [%{at: DateTime.t(), value: Decimal.t()}]
  def profit_series(dataset, grid, display_currency) do
    for t <- grid do
      %{
        at: t,
        value:
          Decimal.sub(
            value_at(dataset, t, display_currency),
            cost_basis_at(dataset, t, display_currency)
          )
      }
    end
  end

  @doc "Total portfolio value at `t` in the display currency."
  @spec value_at(Dataset.t(), DateTime.t(), String.t()) :: Decimal.t()
  def value_at(%Dataset{} = dataset, t, display_currency) do
    dataset.assets
    |> Enum.map(fn {asset_id, %{quote_currency: quote_currency}} ->
      asset_value_at(dataset, asset_id, quote_currency, t, display_currency)
    end)
    |> Enum.reduce(@zero, &Decimal.add/2)
  end

  @doc """
  Net invested capital up to `t` (buys minus sell proceeds, fees included),
  locked to base currency per transaction and re-expressed in the display
  currency at `t`.
  """
  @spec cost_basis_at(Dataset.t(), DateTime.t(), String.t()) :: Decimal.t()
  def cost_basis_at(%Dataset{} = dataset, t, display_currency) do
    dataset
    |> sum_base_cashflows(fn executed_at -> DateTime.compare(executed_at, t) != :gt end)
    |> convert(dataset.base_currency, display_currency, dataset.fx, t)
    |> Kernel.||(@zero)
  end

  @doc """
  Net cashflow within `(window_start, now]`, locked to base per transaction
  and expressed in the display currency at `now`. Subtracting it from the
  window's value change keeps deposits from showing up as profit.
  """
  @spec net_cashflow(Dataset.t(), DateTime.t(), DateTime.t(), String.t()) :: Decimal.t()
  def net_cashflow(%Dataset{} = dataset, window_start, now, display_currency) do
    dataset
    |> sum_base_cashflows(fn executed_at ->
      DateTime.compare(executed_at, window_start) == :gt and
        DateTime.compare(executed_at, now) != :gt
    end)
    |> convert(dataset.base_currency, display_currency, dataset.fx, now)
    |> Kernel.||(@zero)
  end

  @doc "Cumulative signed quantity per asset at `t` (buys +, sells -)."
  @spec holdings_at(Dataset.t(), DateTime.t()) :: %{pos_integer() => Decimal.t()}
  def holdings_at(%Dataset{txns: txns}, t) do
    txns
    |> Enum.take_while(fn %{executed_at: executed_at} ->
      DateTime.compare(executed_at, t) != :gt
    end)
    |> Enum.reduce(%{}, fn txn, acc ->
      Map.update(acc, txn.asset_id, signed_quantity(txn), &Decimal.add(&1, signed_quantity(txn)))
    end)
  end

  @doc """
  Converts an amount between currencies through the EUR pivot at `t`.
  Returns nil when a needed rate is entirely unknown.
  """
  @spec convert(Decimal.t(), String.t(), String.t(), map(), DateTime.t()) :: Decimal.t() | nil
  def convert(amount, currency, currency, _fx, _t), do: amount

  def convert(amount, from_currency, to_currency, fx, t) do
    with %Decimal{} = from_rate <- rate(from_currency, fx, t),
         %Decimal{} = to_rate <- rate(to_currency, fx, t) do
      amount |> Decimal.div(from_rate) |> Decimal.mult(to_rate)
    else
      nil -> nil
    end
  end

  defp asset_value_at(dataset, asset_id, quote_currency, t, display_currency) do
    quantity = Map.get(holdings_at(dataset, t), asset_id, @zero)

    with false <- Decimal.eq?(quantity, @zero),
         %Decimal{} = price <- Lookup.at_or_before(Map.get(dataset.prices, asset_id, []), t),
         %Decimal{} = value <-
           convert(Decimal.mult(quantity, price), quote_currency, display_currency, dataset.fx, t) do
      value
    else
      _missing -> @zero
    end
  end

  defp sum_base_cashflows(%Dataset{txns: txns} = dataset, in_range?) do
    txns
    |> Enum.filter(fn %{executed_at: executed_at} -> in_range?.(executed_at) end)
    |> Enum.map(&base_cashflow(&1, dataset))
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(@zero, &Decimal.add/2)
  end

  # Cashflow in the transaction's own currency, locked into base at execution
  # time: buys cost quantity x price + fee; sells return quantity x price - fee.
  defp base_cashflow(txn, %Dataset{base_currency: base_currency, fx: fx}) do
    %{
      type: type,
      executed_at: executed_at,
      quantity: quantity,
      price_per_unit: price,
      fee: fee,
      currency: currency
    } = txn

    gross = Decimal.mult(quantity, price)

    cashflow =
      case type do
        :buy -> Decimal.add(gross, fee)
        :sell -> gross |> Decimal.sub(fee) |> Decimal.negate()
      end

    convert(cashflow, currency, base_currency, fx, executed_at)
  end

  defp signed_quantity(%{type: :buy, quantity: quantity}), do: quantity
  defp signed_quantity(%{type: :sell, quantity: quantity}), do: Decimal.negate(quantity)

  # 1 EUR = rate x currency. Before the first known rate, the oldest known
  # rate applies (a backfill gap, not a computable value).
  defp rate("EUR", _fx, _t), do: Decimal.new(1)

  defp rate(currency, fx, t) do
    series = Map.get(fx, currency, [])
    Lookup.at_or_before(series, t) || Lookup.oldest(series)
  end
end
