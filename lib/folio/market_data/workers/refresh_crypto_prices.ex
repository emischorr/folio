defmodule Folio.MarketData.Workers.RefreshCryptoPrices do
  @moduledoc """
  Cron (~15 min): fetches current prices for all crypto assets through the
  Quote chain - one batched provider call per quote currency - and stores
  them as intraday ticks. One failed currency group does not fail the others.
  """

  @max_attempts 3
  @snooze_limit 3

  use Oban.Worker, queue: :market_data, max_attempts: @max_attempts

  require Logger

  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.MarketData.Backoff

  @impl true
  def perform(%Oban.Job{} = job) do
    listings = Enum.map(Assets.list_refreshable(:crypto), &Assets.listing/1)

    case listings do
      [] -> :ok
      listings -> refresh_groups(Enum.group_by(listings, & &1.quote_currency), job)
    end
  end

  defp refresh_groups(groups, job) do
    now = DateTime.utc_now()

    results =
      for {_currency, listings} <- groups do
        refresh_group(listings, now)
      end

    cond do
      :rate_limited in results -> Backoff.snooze_or_cancel(job, @max_attempts, @snooze_limit)
      Enum.all?(results, &(&1 == :error)) -> {:error, :all_sources_failed}
      true -> :ok
    end
  end

  defp refresh_group(listings, now) do
    case MarketData.fetch_quotes(listings) do
      {:ok, quotes} ->
        for {asset_id, %{price: price} = quote_result} <- quotes do
          at = quote_result.at || now
          :ok = MarketData.upsert_intraday_prices(asset_id, [%{at: at, price: price}])
        end

        :ok

      {:error, :rate_limited} ->
        :rate_limited

      {:error, :unsupported} ->
        :skipped

      {:error, reason} ->
        Logger.warning("crypto price refresh failed: #{inspect(reason)}")
        :error
    end
  end
end
