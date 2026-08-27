defmodule Folio.MarketData.Workers.BackfillAssetPrices do
  @moduledoc """
  Fetches daily closes for one asset through the History chain and stores
  them.

  The root job (`asset_id` only) derives its window at execution time - back
  to the asset's earliest transaction, or the default initial history,
  whichever reaches further - so repeated triggers collapse (unique per
  asset) without ever dropping a wider request. It fetches the newest chunk
  itself, so the dashboard fills in immediately, and enqueues one job per
  remaining chunk. One chunk means one provider call, and the whole worker
  runs at low priority: a long backfill can never starve the refresh jobs of
  queue slots or budget.
  """

  @max_attempts 5
  @snooze_limit 5
  # Yahoo serves multi-year ranges, CoinGecko caps at ~365 days; one year per
  # chunk keeps every source to one call per job.
  @chunk_days 366

  use Oban.Worker,
    queue: :market_data,
    max_attempts: @max_attempts,
    priority: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:asset_id, :from]
    ]

  require Logger

  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.MarketData.Backoff

  @impl true
  def perform(%Oban.Job{args: %{"asset_id" => asset_id, "from" => from, "to" => to}} = job) do
    case Assets.get_asset(asset_id) do
      # Asset deleted while the job was queued.
      nil -> :ok
      asset -> fetch_chunk(asset, Date.from_iso8601!(from), Date.from_iso8601!(to), job)
    end
  end

  def perform(%Oban.Job{args: %{"asset_id" => asset_id}} = job) do
    case Assets.get_asset(asset_id) do
      nil -> :ok
      asset -> backfill(asset, job)
    end
  end

  defp backfill(asset, job) do
    [{newest_from, newest_to} | older] = chunks(from_date(asset.id), Date.utc_today())

    with :ok <- fetch_chunk(asset, newest_from, newest_to, job) do
      Enum.each(older, fn {from, to} ->
        {:ok, _job} =
          Oban.insert(
            new(%{asset_id: asset.id, from: Date.to_iso8601(from), to: Date.to_iso8601(to)})
          )
      end)

      :ok
    end
  end

  defp fetch_chunk(asset, from, to, job) do
    case asset |> Assets.listing() |> MarketData.fetch_history(from, to) do
      {:ok, entries} ->
        MarketData.upsert_daily_prices(asset.id, entries)

      {:error, :rate_limited} ->
        Backoff.snooze_or_cancel(job, @max_attempts, @snooze_limit)

      # No source can serve this listing (unresolved identity or uncovered
      # venue) - the asset shows as unresolved/stale in the UI; nothing to retry.
      {:error, :unsupported} ->
        Logger.info("no history source supports asset #{asset.id}; skipping backfill")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Newest chunk first.
  defp chunks(from, to) do
    chunk_from = Enum.max([Date.add(to, -(@chunk_days - 1)), from], Date)

    if Date.compare(chunk_from, from) == :gt do
      [{chunk_from, to} | chunks(from, Date.add(chunk_from, -1))]
    else
      [{from, to}]
    end
  end

  # The earliest date this asset needs covered: its oldest transaction, or the
  # default initial history when it has none yet.
  defp from_date(asset_id) do
    default = Date.add(Date.utc_today(), -Assets.initial_history_days())

    case Folio.Portfolios.earliest_transaction_date(asset_id) do
      nil -> default
      earliest -> Enum.min([earliest, default], Date)
    end
  end
end
