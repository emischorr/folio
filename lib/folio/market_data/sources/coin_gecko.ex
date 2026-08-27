defmodule Folio.MarketData.Sources.CoinGecko do
  @moduledoc """
  CoinGecko source - Lookup, History and Quote for crypto.

  Keyless (~5-15 requests/minute); a free demo key (`COINGECKO_API_KEY`)
  raises the limit. The public tier caps `market_chart` history at ~365 days.

  Assets carry only the crypto symbol ("BTC"); the CoinGecko coin id it maps
  to is this source's private concern, resolved via `/search` and cached, with
  pinned overrides for ambiguous symbols in this source's config
  (`config :folio, Folio.MarketData.Sources.CoinGecko, id_overrides: %{"BTC" => "bitcoin"}`).
  """

  @behaviour Folio.MarketData.Sources.Source
  @behaviour Folio.MarketData.Sources.Lookup
  @behaviour Folio.MarketData.Sources.History
  @behaviour Folio.MarketData.Sources.Quote

  import Folio.MarketData.Sources.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  alias Folio.MarketData.Cache

  @base_url "https://api.coingecko.com/api/v3"
  # The public tier rejects market_chart requests beyond one year back.
  @max_history_days 365

  @impl Folio.MarketData.Sources.Source
  def supports?({:text, _query}), do: true
  def supports?({:isin, _value}), do: false
  def supports?({:wkn, _value}), do: false
  def supports?(%{kind: kind}), do: kind == :crypto

  @impl Folio.MarketData.Sources.Lookup
  def lookup({:text, query}) do
    with {:ok, coins} <- search(query) do
      candidates =
        coins
        |> Enum.map(&%{symbol: &1.symbol, name: &1.name})
        # Symbols are shared by copycat coins; /search ranks by market cap,
        # so the first hit per symbol is the one the symbol should mean.
        |> Enum.uniq_by(& &1.symbol)

      {:ok, candidates}
    end
  end

  @impl Folio.MarketData.Sources.History
  def daily_history(%{symbol: symbol, quote_currency: currency}, from, to) do
    days = Date.utc_today() |> Date.diff(from) |> max(1) |> min(@max_history_days)

    params = [vs_currency: String.downcase(currency), days: days, interval: "daily"]

    with {:ok, coin_id} <- coin_id(symbol),
         {:ok, body} <-
           [url: @base_url <> "/coins/#{coin_id}/market_chart", params: params]
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
        |> Enum.filter(&(Date.compare(&1.date, from) != :lt and Date.compare(&1.date, to) != :gt))

      {:ok, entries}
    end
  end

  @impl Folio.MarketData.Sources.Quote
  def fetch_quote(%{asset_id: asset_id} = listing) do
    with {:ok, quotes} <- fetch_quotes([listing]) do
      case quotes do
        %{^asset_id => quote_result} -> {:ok, quote_result}
        _missing -> {:error, :no_quote}
      end
    end
  end

  @impl Folio.MarketData.Sources.Quote
  def fetch_quotes([%{quote_currency: currency} | _rest] = listings) do
    vs = String.downcase(currency)

    resolved =
      for listing <- listings,
          {:ok, coin_id} <- [coin_id(listing.symbol)],
          do: {coin_id, listing}

    fetch_resolved_quotes(resolved, vs, currency)
  end

  defp fetch_resolved_quotes([], _vs, _currency), do: {:ok, %{}}

  defp fetch_resolved_quotes(resolved, vs, currency) do
    params = [ids: Enum.map_join(resolved, ",", &elem(&1, 0)), vs_currencies: vs]

    with {:ok, body} <-
           [url: @base_url <> "/simple/price", params: params] |> request() |> handle() do
      now = DateTime.utc_now()

      quotes =
        for {coin_id, listing} <- resolved,
            %{^vs => price} <- [Map.get(body, coin_id)],
            into: %{} do
          {listing.asset_id, %{price: to_decimal(price), at: now, currency: currency}}
        end

      {:ok, quotes}
    end
  end

  # Symbol -> CoinGecko coin id: pinned override first, else /search cached
  # for a day (ids are stable; a repeat lookup must not spend quota).
  defp coin_id(symbol) do
    case Map.get(config(:id_overrides, %{}), symbol) do
      nil -> Cache.fetch({:coingecko_id, symbol}, id_ttls(), fn -> resolve_id(symbol) end)
      coin_id -> {:ok, coin_id}
    end
  end

  defp resolve_id(symbol) do
    with {:ok, coins} <- search(symbol) do
      case Enum.find(coins, &(&1.symbol == symbol)) do
        nil -> {:error, {:unknown_symbol, symbol}}
        coin -> {:ok, coin.id}
      end
    end
  end

  defp search(query) do
    with {:ok, body} <-
           [url: @base_url <> "/search", params: [query: query]] |> request() |> handle() do
      coins =
        for %{"id" => id, "name" => name, "symbol" => symbol} <- Map.get(body, "coins", []) do
          %{id: id, name: name, symbol: String.upcase(symbol)}
        end

      {:ok, coins}
    end
  end

  defp id_ttls do
    %{ok: config(:id_ttl_ms, :timer.hours(24)), error: :timer.seconds(60)}
  end

  defp config(key, default) do
    :folio |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
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
