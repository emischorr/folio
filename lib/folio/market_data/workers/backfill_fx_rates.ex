defmodule Folio.MarketData.Workers.BackfillFxRates do
  @moduledoc """
  Fetches daily EUR-pivot rates for one currency back to the requested date
  and stores them. Unique per currency.
  """

  @max_attempts 5
  @snooze_limit 5

  use Oban.Worker,
    queue: :market_data,
    max_attempts: @max_attempts,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:currency]
    ]

  alias Folio.MarketData
  alias Folio.MarketData.Backoff

  @impl true
  def perform(%Oban.Job{args: %{"currency" => currency, "from" => from_iso}} = job) do
    from = Date.from_iso8601!(from_iso)

    case MarketData.fetch_historical_rates([currency], from, Date.utc_today()) do
      {:ok, entries} ->
        rows =
          for %{date: date, rates: %{^currency => rate}} <- entries, do: %{date: date, rate: rate}

        MarketData.upsert_fx_rates(currency, rows)

      {:error, :rate_limited} ->
        Backoff.snooze_or_cancel(job, @max_attempts, @snooze_limit)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
