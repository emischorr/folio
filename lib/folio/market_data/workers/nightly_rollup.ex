defmodule Folio.MarketData.Workers.NightlyRollup do
  @moduledoc """
  Cron (nightly, 00:15 UTC): writes yesterday's closes from intraday ticks
  into `daily_prices`, prunes ticks past retention, and refreshes the latest
  FX rates for all currencies in use. Fully idempotent, so retries are safe.
  """

  @max_attempts 3
  @snooze_limit 3

  use Oban.Worker, queue: :market_data, max_attempts: @max_attempts

  alias Folio.Assets
  alias Folio.MarketData
  alias Folio.MarketData.Backoff
  alias Folio.Portfolios

  @impl true
  def perform(%Oban.Job{args: args} = job) do
    # Optional "today" arg supports manual reruns and deterministic tests.
    today = args_today(args)

    MarketData.rollup_day(Date.add(today, -1))

    cutoff =
      DateTime.new!(
        Date.add(today, -MarketData.intraday_retention_days()),
        ~T[00:00:00],
        "Etc/UTC"
      )

    MarketData.prune_intraday(cutoff)

    refresh_fx(job)
  end

  defp refresh_fx(job) do
    currencies =
      (Assets.quote_currencies() ++ Portfolios.transaction_currencies())
      |> Enum.uniq()
      |> Enum.reject(&(&1 == "EUR"))

    case currencies do
      [] -> :ok
      currencies -> fetch_and_store_rates(currencies, job)
    end
  end

  defp fetch_and_store_rates(currencies, job) do
    case fx_client().latest_rates(currencies) do
      {:ok, %{date: date, rates: rates}} ->
        Enum.each(rates, fn {currency, rate} ->
          :ok = MarketData.upsert_fx_rates(currency, [%{date: date, rate: rate}])
        end)

        :ok

      {:error, :rate_limited} ->
        Backoff.snooze_or_cancel(job, @max_attempts, @snooze_limit)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp args_today(%{"today" => iso}), do: Date.from_iso8601!(iso)
  defp args_today(_args), do: Date.utc_today()

  defp fx_client, do: Application.get_env(:folio, :clients)[:fx]
end
