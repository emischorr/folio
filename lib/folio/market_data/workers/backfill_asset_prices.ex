defmodule Folio.MarketData.Workers.BackfillAssetPrices do
  @moduledoc """
  Fetches daily closes for one asset back to the requested date and stores
  them. Unique per asset, so repeated triggers while queued collapse.
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:asset_id]
    ]

  alias Folio.Assets
  alias Folio.MarketData

  @impl true
  def perform(%Oban.Job{args: %{"asset_id" => asset_id, "from" => from_iso}}) do
    case Assets.get_asset(asset_id) do
      # Asset deleted while the job was queued.
      nil -> :ok
      asset -> backfill(asset, Date.from_iso8601!(from_iso))
    end
  end

  defp backfill(asset, from) do
    case fetch_history(asset, from) do
      {:ok, entries} ->
        MarketData.upsert_daily_prices(asset.id, entries)

      {:error, :rate_limited} ->
        {:snooze, 120}

      {:error, reason} ->
        {:error, reason}
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
