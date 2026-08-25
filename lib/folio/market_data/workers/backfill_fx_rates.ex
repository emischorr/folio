defmodule Folio.MarketData.Workers.BackfillFxRates do
  @moduledoc """
  Fetches daily EUR-pivot rates for one currency back to the requested date
  and stores them. Unique per currency.
  """

  use Oban.Worker,
    queue: :market_data,
    max_attempts: 5,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:currency]
    ]

  alias Folio.MarketData

  @impl true
  def perform(%Oban.Job{args: %{"currency" => currency, "from" => from_iso}}) do
    from = Date.from_iso8601!(from_iso)

    case fx_client().historical_rates([currency], from, Date.utc_today()) do
      {:ok, entries} ->
        rows =
          for %{date: date, rates: %{^currency => rate}} <- entries, do: %{date: date, rate: rate}

        MarketData.upsert_fx_rates(currency, rows)

      {:error, :rate_limited} ->
        {:snooze, 120}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fx_client, do: Application.get_env(:folio, :clients)[:fx]
end
