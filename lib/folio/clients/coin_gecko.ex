defmodule Folio.Clients.CoinGecko do
  @moduledoc """
  CoinGecko public API client. Keyless (~5-15 requests/minute); a free demo
  key set via `COINGECKO_API_KEY` raises the limit to 100/minute. Note the
  public tier caps `market_chart` history at ~365 days.
  """

  @behaviour Folio.Clients.CryptoClient

  import Folio.Clients.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  @base_url "https://api.coingecko.com/api/v3"
  # The public tier rejects market_chart requests beyond one year back.
  @max_history_days 365

  @impl true
  def search(query) do
    with {:ok, body} <-
           [url: @base_url <> "/search", params: [query: query]] |> request() |> handle() do
      hits =
        for %{"id" => id, "name" => name, "symbol" => symbol} <- Map.get(body, "coins", []) do
          %{source_id: id, name: name, symbol: String.upcase(symbol)}
        end

      {:ok, hits}
    end
  end

  @impl true
  def daily_history(source_id, vs_currency, days) do
    params = [
      vs_currency: String.downcase(vs_currency),
      days: min(days, @max_history_days),
      interval: "daily"
    ]

    with {:ok, body} <-
           [url: @base_url <> "/coins/#{source_id}/market_chart", params: params]
           |> request()
           |> handle() do
      entries =
        body
        |> Map.get("prices", [])
        |> Enum.map(fn [timestamp_ms, price] ->
          date = timestamp_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
          %{date: date, price: to_decimal(price)}
        end)
        # The final row can be a same-day partial tick; last one per date wins.
        |> Enum.reverse()
        |> Enum.uniq_by(& &1.date)
        |> Enum.reverse()

      {:ok, entries}
    end
  end

  @impl true
  def current_prices(source_ids, vs_currency) do
    vs = String.downcase(vs_currency)
    params = [ids: Enum.join(source_ids, ","), vs_currencies: vs]

    with {:ok, body} <-
           [url: @base_url <> "/simple/price", params: params] |> request() |> handle() do
      prices =
        for {id, %{^vs => price}} <- body, into: %{} do
          {id, to_decimal(price)}
        end

      {:ok, prices}
    end
  end

  defp request(opts) do
    opts
    |> Keyword.merge(headers: api_key_headers())
    |> base()
    |> Req.request()
  end

  defp api_key_headers do
    case Application.get_env(:folio, :coingecko_api_key) do
      nil -> []
      key -> [{"x-cg-demo-api-key", key}]
    end
  end
end
