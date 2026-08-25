defmodule Folio.MarketData do
  @moduledoc """
  Price and FX history: storage, "what do we have" queries, backfill
  triggering, and the nightly rollup/pruning primitives. All prices are
  `Decimal`s in the asset's quote currency; FX rates are daily EUR-pivot rows.
  """

  import Ecto.Query

  alias Folio.MarketData.DailyPrice
  alias Folio.MarketData.FxRate
  alias Folio.MarketData.IntradayPrice
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates
  alias Folio.Repo

  @intraday_retention_days 8

  @doc "Days intraday ticks are retained before the nightly prune."
  @spec intraday_retention_days() :: pos_integer()
  def intraday_retention_days, do: @intraday_retention_days

  @doc "PubSub topic where `{:prices_updated, asset_id}` / `{:fx_updated, currency}` are broadcast after upserts."
  @spec topic() :: String.t()
  def topic, do: "market_data"

  @doc "Idempotently stores daily closes. `entries` is a list of `%{date: Date.t(), price: Decimal.t()}`."
  @spec upsert_daily_prices(pos_integer(), [map()]) :: :ok
  def upsert_daily_prices(asset_id, entries) do
    rows =
      for %{date: date, price: price} <- entries,
          do: %{asset_id: asset_id, date: date, price: price}

    :ok =
      insert_in_batches(DailyPrice, rows,
        on_conflict: {:replace, [:price]},
        conflict_target: [:asset_id, :date]
      )

    broadcast_unless_empty(rows, {:prices_updated, asset_id})
  end

  @doc "Idempotently stores intraday ticks. `entries` is a list of `%{at: DateTime.t(), price: Decimal.t()}`."
  @spec upsert_intraday_prices(pos_integer(), [map()]) :: :ok
  def upsert_intraday_prices(asset_id, entries) do
    rows =
      for %{at: at, price: price} <- entries do
        %{asset_id: asset_id, at: DateTime.truncate(at, :second), price: price}
      end

    :ok =
      insert_in_batches(IntradayPrice, rows,
        on_conflict: {:replace, [:price]},
        conflict_target: [:asset_id, :at]
      )

    broadcast_unless_empty(rows, {:prices_updated, asset_id})
  end

  @doc "Idempotently stores daily EUR-pivot rates. `entries` is a list of `%{date: Date.t(), rate: Decimal.t()}`."
  @spec upsert_fx_rates(String.t(), [map()]) :: :ok
  def upsert_fx_rates(currency, entries) do
    rows =
      for %{date: date, rate: rate} <- entries, do: %{currency: currency, date: date, rate: rate}

    :ok =
      insert_in_batches(FxRate, rows,
        on_conflict: {:replace, [:rate]},
        conflict_target: [:currency, :date]
      )

    broadcast_unless_empty(rows, {:fx_updated, currency})
  end

  @doc "Daily closes for an asset, oldest first. Options: `:from` date."
  @spec daily_prices(pos_integer(), keyword()) :: [%{date: Date.t(), price: Decimal.t()}]
  def daily_prices(asset_id, opts \\ []) do
    from(dp in DailyPrice,
      where: dp.asset_id == ^asset_id,
      order_by: [asc: dp.date],
      select: %{date: dp.date, price: dp.price}
    )
    |> maybe_from(:date, opts[:from])
    |> Repo.all()
  end

  @doc "Intraday ticks for an asset, oldest first. Options: `:from` datetime."
  @spec intraday_prices(pos_integer(), keyword()) :: [%{at: DateTime.t(), price: Decimal.t()}]
  def intraday_prices(asset_id, opts \\ []) do
    from(ip in IntradayPrice,
      where: ip.asset_id == ^asset_id,
      order_by: [asc: ip.at],
      select: %{at: ip.at, price: ip.price}
    )
    |> maybe_from(:at, opts[:from])
    |> Repo.all()
  end

  @doc "Daily EUR-pivot rates for a currency, oldest first. Options: `:from` date."
  @spec fx_rates(String.t(), keyword()) :: [%{date: Date.t(), rate: Decimal.t()}]
  def fx_rates(currency, opts \\ []) do
    from(fx in FxRate,
      where: fx.currency == ^currency,
      order_by: [asc: fx.date],
      select: %{date: fx.date, rate: fx.rate}
    )
    |> maybe_from(:date, opts[:from])
    |> Repo.all()
  end

  @doc "The earliest stored close date for an asset, or nil."
  @spec earliest_daily_price_date(pos_integer()) :: Date.t() | nil
  def earliest_daily_price_date(asset_id) do
    Repo.one(from dp in DailyPrice, where: dp.asset_id == ^asset_id, select: min(dp.date))
  end

  @doc "The earliest stored rate date for a currency, or nil."
  @spec earliest_fx_rate_date(String.t()) :: Date.t() | nil
  def earliest_fx_rate_date(currency) do
    Repo.one(from fx in FxRate, where: fx.currency == ^currency, select: min(fx.date))
  end

  @doc """
  The most recent known price for an asset: the newest intraday tick, falling
  back to the newest daily close (timestamped midnight UTC). Nil if no data.
  """
  @spec latest_price(pos_integer()) :: %{at: DateTime.t(), price: Decimal.t()} | nil
  def latest_price(asset_id) do
    intraday =
      Repo.one(
        from ip in IntradayPrice,
          where: ip.asset_id == ^asset_id,
          order_by: [desc: ip.at],
          limit: 1,
          select: %{at: ip.at, price: ip.price}
      )

    daily =
      Repo.one(
        from dp in DailyPrice,
          where: dp.asset_id == ^asset_id,
          order_by: [desc: dp.date],
          limit: 1,
          select: %{date: dp.date, price: dp.price}
      )

    case {intraday, daily} do
      {nil, nil} ->
        nil

      {tick, nil} ->
        tick

      {nil, close} ->
        %{at: midnight_utc(close.date), price: close.price}

      {tick, close} ->
        Enum.max_by(
          [tick, %{at: midnight_utc(close.date), price: close.price}],
          & &1.at,
          DateTime
        )
    end
  end

  @doc """
  Enqueues backfill jobs so daily prices for the asset and FX rates for its
  quote currency reach back to `from_date`. No-op when history already covers
  it. Duplicate enqueues are absorbed by unique jobs.
  """
  @spec ensure_history(pos_integer(), Date.t(), String.t()) :: :ok
  def ensure_history(asset_id, from_date, quote_currency) do
    if covered?(earliest_daily_price_date(asset_id), from_date) do
      :ok
    else
      {:ok, _job} =
        Oban.insert(
          BackfillAssetPrices.new(%{asset_id: asset_id, from: Date.to_iso8601(from_date)})
        )
    end

    ensure_fx_history(quote_currency, from_date)
  end

  @doc "Enqueues an FX backfill for a non-EUR currency back to `from_date` if uncovered."
  @spec ensure_fx_history(String.t(), Date.t()) :: :ok
  def ensure_fx_history("EUR", _from_date), do: :ok

  def ensure_fx_history(currency, from_date) do
    unless covered?(earliest_fx_rate_date(currency), from_date) do
      {:ok, _job} =
        Oban.insert(BackfillFxRates.new(%{currency: currency, from: Date.to_iso8601(from_date)}))
    end

    :ok
  end

  @doc """
  Writes each asset's last intraday tick of the given UTC day into
  `daily_prices`. Returns how many closes were written.
  """
  @spec rollup_day(Date.t()) :: non_neg_integer()
  def rollup_day(date) do
    day_start = midnight_utc(date)
    day_end = DateTime.add(day_start, 1, :day)

    closes =
      Repo.all(
        from ip in IntradayPrice,
          where: ip.at >= ^day_start and ip.at < ^day_end,
          distinct: ip.asset_id,
          order_by: [asc: ip.asset_id, desc: ip.at],
          select: %{asset_id: ip.asset_id, price: ip.price}
      )

    for %{asset_id: asset_id, price: price} <- closes do
      :ok = upsert_daily_prices(asset_id, [%{date: date, price: price}])
    end

    length(closes)
  end

  @doc "Deletes intraday ticks older than the cutoff. Returns the deleted count."
  @spec prune_intraday(DateTime.t()) :: non_neg_integer()
  def prune_intraday(cutoff) do
    {count, _returning} = Repo.delete_all(from ip in IntradayPrice, where: ip.at < ^cutoff)
    count
  end

  defp covered?(nil, _from_date), do: false
  defp covered?(earliest, from_date), do: Date.compare(earliest, from_date) != :gt

  defp maybe_from(query, _field, nil), do: query
  defp maybe_from(query, :date, from), do: where(query, [row], row.date >= ^from)
  defp maybe_from(query, :at, from), do: where(query, [row], row.at >= ^from)

  defp midnight_utc(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp broadcast_unless_empty([], _message), do: :ok

  defp broadcast_unless_empty(_rows, message) do
    Phoenix.PubSub.broadcast(Folio.PubSub, topic(), message)
  end

  defp insert_in_batches(schema, rows, opts) do
    rows
    |> Enum.chunk_every(1000)
    |> Enum.each(fn chunk -> Repo.insert_all(schema, chunk, opts) end)
  end
end
