defmodule Folio.MarketData do
  @moduledoc """
  Price and FX history: storage, "what do we have" queries, backfill
  triggering, and the nightly rollup/pruning primitives. All prices are
  `Decimal`s in the asset's quote currency; FX rates are daily EUR-pivot rows.
  """

  import Ecto.Query

  alias Folio.MarketData.Cache
  alias Folio.MarketData.Chain
  alias Folio.MarketData.DailyPrice
  alias Folio.MarketData.FxRate
  alias Folio.MarketData.IntradayPrice
  alias Folio.MarketData.Listing
  alias Folio.MarketData.SourceStats
  alias Folio.MarketData.Sources.Lookup
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

  @doc """
  Candidate listings for user input, via the configured Lookup chain.

  `kind` picks the chain (`:security` or `:crypto`); a bare string is treated
  as free text. Results and rate-limit refusals are cached briefly so a
  repeated search never spends fresh provider quota.
  """
  @spec lookup(:security | :crypto, Lookup.input() | String.t()) ::
          {:ok, [map()]} | {:error, :unsupported | :rate_limited | :failed}
  def lookup(kind, input) when kind in [:security, :crypto] do
    input = normalize_lookup_input(input)

    Cache.fetch({:lookup, kind, input}, lookup_ttls(), fn ->
      Chain.run(:lookup, sources(kind, :lookup), input, & &1.lookup(input))
    end)
  end

  @doc "Daily closes for a listing within `[from, to]`, via the History chain."
  @spec fetch_history(Listing.t(), Date.t(), Date.t()) ::
          {:ok, [%{date: Date.t(), price: Decimal.t()}]}
          | {:error, :unsupported | :rate_limited | :failed}
  def fetch_history(%{kind: kind} = listing, from, to) do
    Chain.run(
      :history,
      sources(chain_kind(kind), :history),
      listing,
      & &1.daily_history(listing, from, to)
    )
  end

  @doc "Latest (possibly delayed) price for a listing, via the Quote chain."
  @spec fetch_quote(Listing.t()) ::
          {:ok, %{price: Decimal.t(), at: DateTime.t() | nil, currency: String.t() | nil}}
          | {:error, :unsupported | :rate_limited | :failed}
  def fetch_quote(%{kind: kind} = listing) do
    Chain.run(:quote, sources(chain_kind(kind), :quote), listing, & &1.fetch_quote(listing))
  end

  @doc """
  Latest prices for several same-kind, same-currency listings, keyed by asset
  id. Sources exporting the batch callback answer one provider call for the
  whole group.
  """
  @spec fetch_quotes([Listing.t()]) ::
          {:ok, %{pos_integer() => map()}} | {:error, :unsupported | :rate_limited | :failed}
  def fetch_quotes([%{kind: kind} | _rest] = listings) do
    Chain.run(
      :quote,
      sources(chain_kind(kind), :quote),
      hd(listings),
      &batch_quotes(&1, listings)
    )
  end

  @doc "Latest ECB reference rates via the FX source (chain-run for uniform stats)."
  @spec fetch_latest_rates([String.t()]) ::
          {:ok, %{date: Date.t(), rates: map()}}
          | {:error, :unsupported | :rate_limited | :failed}
  def fetch_latest_rates(currencies) do
    Chain.run(:fx, [fx_source()], nil, & &1.latest_rates(currencies))
  end

  @doc "Historical ECB reference rates via the FX source."
  @spec fetch_historical_rates([String.t()], Date.t(), Date.t()) ::
          {:ok, [%{date: Date.t(), rates: map()}]}
          | {:error, :unsupported | :rate_limited | :failed}
  def fetch_historical_rates(currencies, from, to) do
    Chain.run(:fx, [fx_source()], nil, & &1.historical_rates(currencies, from, to))
  end

  @doc "Per-source outcome counters, for debugging a silently broken source."
  @spec source_stats() :: %{{atom(), atom(), atom()} => pos_integer()}
  def source_stats, do: SourceStats.snapshot()

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
  it. Duplicate enqueues are absorbed by unique jobs; the price backfill
  derives its own window at execution time, so an absorbed enqueue still
  widens the range rather than dropping it.
  """
  @spec ensure_history(pos_integer(), Date.t(), String.t()) :: :ok
  def ensure_history(asset_id, from_date, quote_currency) do
    unless covered?(earliest_daily_price_date(asset_id), from_date) do
      {:ok, _job} = Oban.insert(BackfillAssetPrices.new(%{asset_id: asset_id}))
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
  Cancels any live price backfill for the asset and enqueues a fresh one,
  bypassing both the coverage check and job uniqueness. The operator escape
  hatch for a backfill that failed or is backing off - call it from
  `bin/folio remote`.
  """
  @spec force_backfill(pos_integer()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def force_backfill(asset_id) do
    [worker: BackfillAssetPrices, args: %{asset_id: asset_id}]
    |> Oban.Job.query()
    |> Oban.cancel_all_jobs()

    Oban.insert(BackfillAssetPrices.new(%{asset_id: asset_id}))
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

  @doc """
  The most recent known price per asset id, like `latest_price/1` but one
  query pair for a whole holdings list.
  """
  @spec latest_prices([pos_integer()]) ::
          %{pos_integer() => %{at: DateTime.t(), price: Decimal.t()}}
  def latest_prices(asset_ids) do
    intraday =
      Repo.all(
        from ip in IntradayPrice,
          where: ip.asset_id in ^asset_ids,
          distinct: ip.asset_id,
          order_by: [asc: ip.asset_id, desc: ip.at],
          select: %{asset_id: ip.asset_id, at: ip.at, price: ip.price}
      )

    daily =
      Repo.all(
        from dp in DailyPrice,
          where: dp.asset_id in ^asset_ids,
          distinct: dp.asset_id,
          order_by: [asc: dp.asset_id, desc: dp.date],
          select: %{asset_id: dp.asset_id, date: dp.date, price: dp.price}
      )

    daily_map =
      Map.new(daily, &{&1.asset_id, %{at: midnight_utc(&1.date), price: &1.price}})

    intraday_map = Map.new(intraday, &{&1.asset_id, %{at: &1.at, price: &1.price}})

    Map.merge(daily_map, intraday_map, fn _asset_id, close, tick ->
      Enum.max_by([close, tick], & &1.at, DateTime)
    end)
  end

  defp normalize_lookup_input({_type, _value} = input), do: input
  defp normalize_lookup_input(query) when is_binary(query), do: {:text, query}

  defp lookup_ttls do
    config = Application.get_env(:folio, :search_cache, [])
    %{ok: Keyword.get(config, :ok_ttl_ms, 0), error: Keyword.get(config, :error_ttl_ms, 0)}
  end

  defp sources(kind, concern) do
    :folio
    |> Application.get_env(:market_data_sources, [])
    |> get_in([kind, concern]) || []
  end

  defp chain_kind(:crypto), do: :crypto
  defp chain_kind(_security), do: :security

  defp fx_source, do: Application.get_env(:folio, :market_data_sources, [])[:fx]

  defp batch_quotes(source, listings) do
    if function_exported?(source, :fetch_quotes, 1) do
      source.fetch_quotes(listings)
    else
      quotes =
        for listing <- listings,
            {:ok, quote_result} <- [source.fetch_quote(listing)],
            into: %{},
            do: {listing.asset_id, quote_result}

      {:ok, quotes}
    end
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
