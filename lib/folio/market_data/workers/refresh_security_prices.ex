defmodule Folio.MarketData.Workers.RefreshSecurityPrices do
  @moduledoc """
  Cron (~30 min): fetches the current price of each resolved security through
  the Quote chain and stores it as an intraday tick. Listings whose venue is
  closed (per `Folio.MarketData.Markets` trading hours) are skipped, so a
  throttled budget is never spent on a market that cannot have moved. One
  failed listing does not fail the others.
  """

  @max_attempts 3
  @snooze_limit 3

  use Oban.Worker, queue: :market_data, max_attempts: @max_attempts

  require Logger

  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.MarketData.Backoff
  alias Folio.MarketData.Markets

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    now = args_now(args)

    listings =
      Assets.list_refreshable(:security)
      |> Enum.map(&Assets.listing/1)
      |> Enum.filter(&Markets.open?(&1.mic, now))

    refresh(listings, now, job)
  end

  defp refresh([], _now, _job), do: :ok

  defp refresh(listings, now, job) do
    results = for listing <- listings, do: refresh_listing(listing, now)

    cond do
      :rate_limited in results -> Backoff.snooze_or_cancel(job, @max_attempts, @snooze_limit)
      Enum.all?(results, &(&1 == :error)) -> {:error, :all_sources_failed}
      true -> :ok
    end
  end

  defp refresh_listing(listing, now) do
    case MarketData.fetch_quote(listing) do
      {:ok, %{price: price} = quote_result} ->
        store_tick(listing, price, quote_result, now)

      {:error, :rate_limited} ->
        :rate_limited

      # No source covers this venue; the asset keeps its last known price.
      {:error, :unsupported} ->
        :skipped

      {:error, reason} ->
        Logger.warning("price refresh failed for asset #{listing.asset_id}: #{inspect(reason)}")
        :error
    end
  end

  defp store_tick(listing, price, quote_result, now) do
    if currency_matches?(listing.quote_currency, quote_result.currency) do
      at = quote_result.at || now
      :ok = MarketData.upsert_intraday_prices(listing.asset_id, [%{at: at, price: price}])
      :ok
    else
      Logger.warning(
        "quote currency #{inspect(quote_result.currency)} does not match asset " <>
          "#{listing.asset_id} (#{listing.quote_currency}); tick dropped"
      )

      :error
    end
  end

  defp currency_matches?(_asset_currency, nil), do: true
  defp currency_matches?(asset_currency, quote_currency), do: asset_currency == quote_currency

  # Optional "now" arg supports manual reruns and deterministic tests.
  defp args_now(%{"now" => iso}) do
    {:ok, now, _offset} = DateTime.from_iso8601(iso)
    now
  end

  defp args_now(_args), do: DateTime.utc_now()
end
