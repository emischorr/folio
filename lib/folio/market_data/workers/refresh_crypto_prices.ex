defmodule Folio.MarketData.Workers.RefreshCryptoPrices do
  @moduledoc """
  Cron (~15 min): fetches current prices for all crypto assets in one batched
  call per quote currency and stores them as intraday ticks. One failed
  currency group does not fail the others.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Folio.Assets
  alias Folio.MarketData

  @impl true
  def perform(%Oban.Job{}) do
    assets = Assets.list_assets_by_source(:coingecko)

    case assets do
      [] -> :ok
      assets -> refresh_groups(Enum.group_by(assets, & &1.quote_currency))
    end
  end

  defp refresh_groups(groups) do
    now = DateTime.utc_now()

    results =
      for {vs_currency, assets} <- groups do
        refresh_group(vs_currency, assets, now)
      end

    cond do
      :rate_limited in results -> {:snooze, 120}
      Enum.all?(results, &(&1 != :ok)) -> {:error, :all_sources_failed}
      true -> :ok
    end
  end

  defp refresh_group(vs_currency, assets, now) do
    case crypto_client().current_prices(Enum.map(assets, & &1.source_id), vs_currency) do
      {:ok, prices} ->
        for asset <- assets, price = prices[asset.source_id], not is_nil(price) do
          :ok = MarketData.upsert_intraday_prices(asset.id, [%{at: now, price: price}])
        end

        :ok

      {:error, :rate_limited} ->
        :rate_limited

      {:error, reason} ->
        Logger.warning("crypto price refresh failed for #{vs_currency}: #{inspect(reason)}")
        :error
    end
  end

  defp crypto_client, do: Application.get_env(:folio, :clients)[:crypto]
end
