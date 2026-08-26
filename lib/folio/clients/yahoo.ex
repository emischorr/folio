defmodule Folio.Clients.Yahoo do
  @moduledoc """
  Yahoo Finance client (unofficial, keyless). Requires a browser User-Agent.
  Search results carry no currency; `quote_meta/1` reads it from the chart
  endpoint's metadata. The most fragile provider - see README "Data sources".
  """

  @behaviour Folio.Clients.EquityClient

  import Folio.Clients.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  @base_url "https://query1.finance.yahoo.com"
  # Yahoo types many European ETF and ETC listings as MUTUALFUND - excluding
  # that type hides whole exchanges (Stuttgart in particular).
  @quote_types %{"EQUITY" => :stock, "ETF" => :etf, "MUTUALFUND" => :etf}
  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  @impl true
  def search(query) do
    params = [q: query, quotesCount: 20, newsCount: 0]

    with {:ok, body} <-
           [url: @base_url <> "/v1/finance/search", params: params] |> request() |> handle() do
      hits =
        body
        |> Map.get("quotes", [])
        |> Enum.filter(&(is_map_key(@quote_types, &1["quoteType"]) and is_binary(&1["symbol"])))
        |> Enum.map(fn quote_hit ->
          %{
            symbol: quote_hit["symbol"],
            name: quote_hit["longname"] || quote_hit["shortname"] || quote_hit["symbol"],
            exchange: quote_hit["exchDisp"] || quote_hit["exchange"],
            kind: @quote_types[quote_hit["quoteType"]]
          }
        end)

      {:ok, hits}
    end
  end

  @impl true
  def quote_meta(symbol) do
    with {:ok, meta, _timestamps, _closes} <- fetch_chart(symbol, range: "1d", interval: "1d") do
      {:ok,
       %{
         currency: meta["currency"],
         exchange: meta["fullExchangeName"] || meta["exchangeName"],
         price: to_decimal(meta["regularMarketPrice"])
       }}
    end
  end

  @impl true
  def daily_history(symbol, from) do
    period1 = from |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    period2 = DateTime.to_unix(DateTime.utc_now())

    with {:ok, _meta, timestamps, closes} <-
           fetch_chart(symbol, period1: period1, period2: period2, interval: "1d") do
      entries =
        timestamps
        |> Enum.zip(closes)
        |> Enum.reject(fn {_timestamp, close} -> is_nil(close) end)
        |> Enum.map(fn {timestamp, close} ->
          date = timestamp |> DateTime.from_unix!() |> DateTime.to_date()
          %{date: date, price: to_decimal(close)}
        end)
        # Same-day duplicates (partial trading day): the later value wins.
        |> Enum.reverse()
        |> Enum.uniq_by(& &1.date)
        |> Enum.reverse()

      {:ok, entries}
    end
  end

  defp fetch_chart(symbol, params) do
    with {:ok, body} <-
           [url: @base_url <> "/v8/finance/chart/#{symbol}", params: params]
           |> request()
           |> handle() do
      case body do
        %{"chart" => %{"result" => [%{"meta" => meta} = result | _rest]}} ->
          timestamps = Map.get(result, "timestamp", [])
          closes = get_in(result, ["indicators", "quote", Access.at(0), "close"]) || []
          {:ok, meta, timestamps, closes}

        %{"chart" => %{"error" => error}} when not is_nil(error) ->
          {:error, {:provider, error}}

        _other ->
          {:error, :unexpected_response}
      end
    end
  end

  defp request(opts) do
    opts
    |> Keyword.merge(headers: [{"user-agent", @user_agent}])
    |> base()
    |> Req.request()
  end
end
