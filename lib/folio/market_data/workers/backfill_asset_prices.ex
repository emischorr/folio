defmodule Folio.MarketData.Workers.BackfillAssetPrices do
  @moduledoc """
  Fetches daily closes for one asset and stores them. The window is derived at
  execution time - back to the asset's earliest transaction, or the default
  initial history, whichever reaches further - so a job queued for a narrow
  window still widens to whatever the data now demands. That is what makes
  uniqueness on `:asset_id` alone correct: repeated triggers collapse without
  ever dropping a wider request.
  """

  @max_attempts 5
  @snooze_limit 5

  use Oban.Worker,
    queue: :market_data,
    max_attempts: @max_attempts,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:asset_id]
    ]

  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.MarketData.Backoff
  alias Folio.Portfolios

  @impl true
  def perform(%Oban.Job{args: %{"asset_id" => asset_id}} = job) do
    case Assets.get_asset(asset_id) do
      # Asset deleted while the job was queued.
      nil -> :ok
      asset -> backfill(asset, from_date(asset_id), job)
    end
  end

  defp backfill(asset, from, job) do
    case fetch_history(asset, from) do
      {:ok, entries} ->
        MarketData.upsert_daily_prices(asset.id, entries)

      {:error, :rate_limited} ->
        Backoff.snooze_or_cancel(job, @max_attempts, @snooze_limit)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The earliest date this asset needs covered: its oldest transaction, or the
  # default initial history when it has none yet.
  defp from_date(asset_id) do
    default = Date.add(Date.utc_today(), -Assets.initial_history_days())

    case Portfolios.earliest_transaction_date(asset_id) do
      nil -> default
      earliest -> Enum.min([earliest, default], Date)
    end
  end

  defp fetch_history(%{price_source: :coingecko} = asset, from) do
    days = max(Date.diff(Date.utc_today(), from), 1)
    crypto_client().daily_history(asset.source_id, asset.quote_currency, days)
  end

  defp fetch_history(%{price_source: :yahoo} = asset, from) do
    equity_client().daily_history(asset.source_id, from)
  end

  defp crypto_client, do: Application.get_env(:folio, :clients)[:crypto]
  defp equity_client, do: Application.get_env(:folio, :clients)[:equity]
end
