defmodule Folio.MarketDataFixtures do
  @moduledoc """
  Deterministic price/FX series builders for tests. Weekday-only series mimic
  equity and ECB data so weekend-gap handling gets exercised.
  """

  alias Folio.MarketData

  @doc """
  Stores a linear daily close series: `start_price` on `from`, changing by
  `step` per day. Option `weekdays_only: true` skips Saturdays and Sundays.
  Returns the stored entries.
  """
  @spec seed_daily_prices(pos_integer(), Date.t(), Date.t(), String.t(), String.t(), keyword()) ::
          [%{date: Date.t(), price: Decimal.t()}]
  def seed_daily_prices(asset_id, from, to, start_price, step, opts \\ []) do
    entries = linear_series(from, to, start_price, step, opts)
    :ok = MarketData.upsert_daily_prices(asset_id, entries)
    entries
  end

  @doc "Stores a linear EUR-pivot FX series, weekdays only by default (like ECB)."
  @spec seed_fx_rates(String.t(), Date.t(), Date.t(), String.t(), String.t(), keyword()) ::
          [%{date: Date.t(), rate: Decimal.t()}]
  def seed_fx_rates(currency, from, to, start_rate, step, opts \\ []) do
    opts = Keyword.put_new(opts, :weekdays_only, true)

    entries =
      for %{date: date, price: price} <- linear_series(from, to, start_rate, step, opts) do
        %{date: date, rate: price}
      end

    :ok = MarketData.upsert_fx_rates(currency, entries)
    entries
  end

  @doc "Stores intraday ticks every `interval_minutes` between two datetimes, all at `price`."
  @spec seed_intraday_prices(pos_integer(), DateTime.t(), DateTime.t(), String.t(), pos_integer()) ::
          [%{at: DateTime.t(), price: Decimal.t()}]
  def seed_intraday_prices(asset_id, from, to, price, interval_minutes \\ 15) do
    entries =
      from
      |> Stream.iterate(&DateTime.add(&1, interval_minutes * 60, :second))
      |> Enum.take_while(&(DateTime.compare(&1, to) != :gt))
      |> Enum.map(&%{at: &1, price: Decimal.new(price)})

    :ok = MarketData.upsert_intraday_prices(asset_id, entries)
    entries
  end

  defp linear_series(from, to, start_value, step, opts) do
    weekdays_only = Keyword.get(opts, :weekdays_only, false)

    from
    |> Date.range(to)
    |> Enum.with_index()
    |> Enum.reject(fn {date, _index} -> weekdays_only and Date.day_of_week(date) in [6, 7] end)
    |> Enum.map(fn {date, index} ->
      %{
        date: date,
        price: Decimal.add(Decimal.new(start_value), Decimal.mult(Decimal.new(step), index))
      }
    end)
  end
end
