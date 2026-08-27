defmodule Folio.MarketData.Sources.Yahoo do
  @moduledoc """
  Yahoo Finance source (unofficial, keyless) - Lookup, History and Quote.

  The most fragile and rate-scarce provider (see README), so it is
  configured last in every chain and its token bucket is the tightest.
  Requires a browser User-Agent. The EU consent/crumb handshake Yahoo
  sometimes demands from German IPs is deliberately not implemented; when it
  bites, this source fails and the chain falls through.

  Yahoo symbols are built here from the asset's general identity: exchange
  ticker plus a per-MIC suffix, with per-ISIN overrides in this source's
  config for listings whose Yahoo naming breaks the rule
  (`config :folio, Folio.MarketData.Sources.Yahoo, symbol_overrides: %{"IE.." => "SPYY.DE"}`).
  """

  @behaviour Folio.MarketData.Sources.Source
  @behaviour Folio.MarketData.Sources.Lookup
  @behaviour Folio.MarketData.Sources.History
  @behaviour Folio.MarketData.Sources.Quote

  import Folio.MarketData.Sources.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  alias Folio.MarketData.Markets

  @base_url "https://query1.finance.yahoo.com"
  # Yahoo types many European ETF and ETC listings as MUTUALFUND - excluding
  # that type hides whole exchanges (Stuttgart in particular).
  @quote_types %{"EQUITY" => :stock, "ETF" => :etf, "MUTUALFUND" => :etf}
  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  @mic_to_suffix %{
    "XETR" => ".DE",
    "XFRA" => ".F",
    "XSTU" => ".SG",
    "XMUN" => ".MU",
    "XBER" => ".BE",
    "XDUS" => ".DU",
    "XHAM" => ".HM",
    "XHAN" => ".HA",
    "XLON" => ".L",
    "XMIL" => ".MI",
    "XAMS" => ".AS",
    "XPAR" => ".PA",
    "XSWX" => ".SW",
    "XWBO" => ".VI",
    "XTSE" => ".TO",
    "XHKG" => ".HK",
    "XNAS" => "",
    "XNYS" => "",
    "ARCX" => ""
  }

  @suffix_to_mic @mic_to_suffix
                 |> Enum.reject(fn {_mic, suffix} -> suffix == "" end)
                 |> Map.new(fn {mic, suffix} -> {suffix, mic} end)

  # Suffix-less symbols are US listings; Yahoo's search "exchange" code says which.
  @us_exchange_to_mic %{
    "NMS" => "XNAS",
    "NGM" => "XNAS",
    "NCM" => "XNAS",
    "NAS" => "XNAS",
    "NYQ" => "XNYS",
    "PCX" => "ARCX"
  }

  # Words that make an official fund name unsearchable on Yahoo.
  @name_noise ~w(UCITS ETF ETC FUND)
  @name_keep_words 4

  @impl Folio.MarketData.Sources.Source
  def supports?({:isin, _value}), do: true
  def supports?({:wkn, _value}), do: false
  def supports?({:text, _query}), do: true
  def supports?(%{kind: kind} = listing), do: kind != :crypto and symbol_for(listing) != nil

  @impl Folio.MarketData.Sources.Lookup
  def lookup({:isin, isin}) do
    with {:ok, candidates} <- search_candidates(isin) do
      {:ok, Enum.map(candidates, &%{&1 | isin: isin})}
    end
  end

  def lookup({:text, query}) do
    case search_candidates(query) do
      {:ok, []} -> retry_lookup(query)
      result -> result
    end
  end

  @impl Folio.MarketData.Sources.History
  def daily_history(listing, from, to) do
    period1 = from |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()
    period2 = to |> Date.add(1) |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_unix()

    with {:ok, _meta, timestamps, closes} <-
           fetch_chart(symbol_for(listing), period1: period1, period2: period2, interval: "1d") do
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

  @impl Folio.MarketData.Sources.Quote
  def fetch_quote(listing) do
    with {:ok, meta, _timestamps, _closes} <-
           fetch_chart(symbol_for(listing), range: "1d", interval: "1d") do
      {:ok,
       %{
         price: to_decimal(meta["regularMarketPrice"]),
         at: quote_time(meta),
         currency: meta["currency"]
       }}
    end
  end

  defp quote_time(%{"regularMarketTime" => unix}) when is_integer(unix),
    do: DateTime.from_unix!(unix)

  defp quote_time(_meta), do: DateTime.utc_now()

  # The Yahoo symbol for a listing: per-ISIN override first, else ticker +
  # per-MIC suffix. Nil when the listing cannot be expressed as a Yahoo symbol.
  defp symbol_for(%{isin: isin, ticker: ticker, mic: mic}) do
    case symbol_overrides() do
      %{^isin => symbol} -> symbol
      _overrides -> suffixed_symbol(ticker, mic)
    end
  end

  defp suffixed_symbol(ticker, mic) when is_binary(ticker) do
    case Map.get(@mic_to_suffix, mic) do
      nil -> nil
      suffix -> ticker <> suffix
    end
  end

  defp suffixed_symbol(_ticker, _mic), do: nil

  defp symbol_overrides do
    :folio |> Application.get_env(__MODULE__, []) |> Keyword.get(:symbol_overrides, %{})
  end

  defp search_candidates(query) do
    params = [q: query, quotesCount: 20, newsCount: 0]

    with {:ok, body} <-
           [url: @base_url <> "/v1/finance/search", params: params] |> request() |> handle() do
      candidates =
        body
        |> Map.get("quotes", [])
        |> Enum.filter(&(is_map_key(@quote_types, &1["quoteType"]) and is_binary(&1["symbol"])))
        |> Enum.flat_map(&to_candidate/1)
        |> Enum.uniq_by(&{&1.ticker, &1.mic})

      {:ok, candidates}
    end
  end

  defp to_candidate(quote_hit) do
    case ticker_and_mic(quote_hit["symbol"], quote_hit["exchange"]) do
      nil ->
        []

      {ticker, mic} ->
        [
          %{
            kind: @quote_types[quote_hit["quoteType"]],
            isin: nil,
            mic: mic,
            ticker: ticker,
            name: quote_hit["longname"] || quote_hit["shortname"] || quote_hit["symbol"],
            quote_currency: Markets.currency(mic)
          }
        ]
    end
  end

  defp ticker_and_mic(symbol, exchange_code) do
    case String.split(symbol, ".") do
      [ticker, suffix] ->
        with mic when not is_nil(mic) <- Map.get(@suffix_to_mic, "." <> suffix), do: {ticker, mic}

      [ticker] ->
        with mic when not is_nil(mic) <- Map.get(@us_exchange_to_mic, exchange_code),
             do: {ticker, mic}

      _multi_dot ->
        nil
    end
  end

  # The official fund name ("... UCITS ETF (Acc)") often scores nothing on
  # Yahoo; retry with the noise trimmed, then with the first few words.
  defp retry_lookup(query) do
    query
    |> fallback_queries()
    |> Enum.reduce_while({:ok, []}, fn fallback, acc ->
      case search_candidates(fallback) do
        {:ok, []} -> {:cont, acc}
        {:ok, candidates} -> {:halt, {:ok, candidates}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fallback_queries(query) do
    words =
      query
      |> String.replace(~r/\([^)]*\)/, " ")
      |> String.split(~r/\s+/, trim: true)
      |> Enum.reject(&(String.upcase(&1) in @name_noise))

    [Enum.join(words, " "), words |> Enum.take(@name_keep_words) |> Enum.join(" ")]
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "" or &1 == query))
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
