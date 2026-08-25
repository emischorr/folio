defmodule Folio.MarketData.Workers.RefreshEquityPrices do
  @moduledoc """
  Cron (~30 min): fetches the current price of each stock/ETF asset and
  stores it as an intraday tick. No-op outside a deliberately coarse
  Mon-Fri 06:00-22:00 UTC window covering European and US trading hours.
  One failed symbol does not fail the others.
  """

  use Oban.Worker, queue: :market_data, max_attempts: 3

  require Logger

  alias Folio.Assets
  alias Folio.MarketData

  @impl true
  def perform(%Oban.Job{args: args}) do
    now = args_now(args)

    if trading_hours?(now) do
      refresh(Assets.list_assets_by_source(:yahoo), now)
    else
      :ok
    end
  end

  @doc "Whether the coarse global trading window (Mon-Fri 06:00-22:00 UTC) is open."
  @spec trading_hours?(DateTime.t()) :: boolean()
  def trading_hours?(now) do
    Date.day_of_week(DateTime.to_date(now)) in 1..5 and now.hour >= 6 and now.hour < 22
  end

  defp refresh([], _now), do: :ok

  defp refresh(assets, now) do
    results = for asset <- assets, do: refresh_asset(asset, now)

    cond do
      :rate_limited in results -> {:snooze, 120}
      Enum.all?(results, &(&1 != :ok)) -> {:error, :all_sources_failed}
      true -> :ok
    end
  end

  defp refresh_asset(asset, now) do
    case equity_client().quote_meta(asset.source_id) do
      {:ok, %{price: price}} ->
        :ok = MarketData.upsert_intraday_prices(asset.id, [%{at: now, price: price}])
        :ok

      {:error, :rate_limited} ->
        :rate_limited

      {:error, reason} ->
        Logger.warning("equity price refresh failed for #{asset.source_id}: #{inspect(reason)}")
        :error
    end
  end

  # Optional "now" arg supports manual reruns and deterministic tests.
  defp args_now(%{"now" => iso}) do
    {:ok, now, _offset} = DateTime.from_iso8601(iso)
    now
  end

  defp args_now(_args), do: DateTime.utc_now()

  defp equity_client, do: Application.get_env(:folio, :clients)[:equity]
end
