defmodule Folio.Assets.Resolver do
  @moduledoc """
  Turns a user-typed query into asset candidates: local matches first, then
  remote search.

  The query is classified first. An ISIN usually resolves on the equity
  provider directly; when it does not, and for every WKN, the security-id
  provider maps the identifier to tickers which are then searched on the
  equity provider. The identifier is stamped onto every resulting candidate,
  because no price provider ever returns one. Plain text goes to CoinGecko
  and the equity provider, with a trimmed retry when the full official fund
  name ("... UCITS ETF (Acc)") scores nothing.

  Equity search results carry no currency, so the top hits are enriched
  through `quote_meta/1` concurrently; enrichment failures leave the currency
  nil rather than dropping the hit. Remote outages degrade to local-only
  results.
  """

  alias Folio.Assets
  alias Folio.Assets.Candidate
  alias Folio.Assets.Identifier
  alias Folio.Assets.SearchCache

  @remote_limit 6
  @ticker_limit 3
  @per_ticker_limit 3
  @enrich_concurrency 5
  # Words that make an official fund name unsearchable on the equity provider.
  @name_noise ~w(UCITS ETF ETC FUND)
  @name_keep_words 4

  @typedoc "Health of the remote providers consulted for a query."
  @type status :: :ok | :rate_limited | :unavailable

  @doc """
  Resolves a query into an ordered candidate list (local first) plus the
  health of the remote providers, so the UI can tell "nothing matched" apart
  from "the provider refused to answer".
  """
  @spec resolve(String.t()) :: %{candidates: [Candidate.t()], status: status()}
  def resolve(query) do
    local = query |> Assets.search_local() |> Enum.map(&Candidate.from_asset/1)
    known = MapSet.new(local, &{&1.price_source, &1.source_id})

    {hits, status} = query |> Identifier.classify() |> remote_candidates(query)

    remote =
      hits
      |> Enum.uniq_by(&{&1.price_source, &1.source_id})
      |> Enum.reject(&MapSet.member?(known, {&1.price_source, &1.source_id}))

    %{candidates: local ++ remote, status: status}
  end

  defp remote_candidates({:isin, isin}, _query) do
    {hits, status} = identifier_hits(isin, :isin)

    {hits |> stamp(isin: isin) |> enrich_equities(), status}
  end

  defp remote_candidates({:wkn, wkn}, query) do
    {identified, id_status} = identifier_hits(wkn, :wkn)
    # A six-character query is just as likely to be a ticker, so keep the
    # plain-text results too.
    {text, text_status} = equity_hits(query)
    {crypto, crypto_status} = crypto_candidates(query)

    equities = enrich_equities(stamp(identified, wkn: wkn) ++ text)

    {equities ++ crypto, worst_status([id_status, text_status, crypto_status])}
  end

  defp remote_candidates(:text, query) do
    {crypto, crypto_status} = crypto_candidates(query)
    {equities, equity_status} = equity_hits(query)

    {crypto ++ enrich_equities(equities), worst_status([crypto_status, equity_status])}
  end

  # The equity provider resolves many ISINs directly, and hands back the exact
  # listing with its exchange - so the security-id provider is only consulted
  # when that comes up empty, which keeps the common case to one request. A
  # WKN never resolves on the equity provider, so it always takes the hop.
  defp identifier_hits(value, :isin) do
    case equity_hits(value) do
      {[], status} -> merge_results({[], status}, ticker_hits(value, :isin))
      found -> found
    end
  end

  defp identifier_hits(value, :wkn), do: ticker_hits(value, :wkn)

  defp ticker_hits(value, id_type) do
    case cached_lookup(id_type, value) do
      {:ok, hits} ->
        hits
        |> Enum.take(@ticker_limit)
        |> Enum.reduce({[], :ok}, &merge_results(&2, listings_for(&1.ticker)))

      {:error, reason} ->
        {[], status_for(reason)}
    end
  end

  # A ticker search returns every symbol that starts with it, so keep only the
  # listings of this instrument.
  defp listings_for(ticker) do
    {hits, status} = equity_hits(ticker)

    listings =
      hits
      |> Enum.filter(&(base_symbol(&1.symbol) == ticker))
      |> Enum.take(@per_ticker_limit)

    {listings, status}
  end

  defp equity_hits(query) do
    case cached_search(query) do
      {:ok, []} -> retry_hits(query)
      {:ok, hits} -> {Enum.take(hits, @remote_limit), :ok}
      {:error, reason} -> {[], status_for(reason)}
    end
  end

  # Only ever reached on an empty result, so ordinary queries pay nothing.
  defp retry_hits(query) do
    query
    |> fallback_queries()
    |> Enum.reduce_while({[], :ok}, fn fallback, acc ->
      case cached_search(fallback) do
        {:ok, []} -> {:cont, acc}
        {:ok, hits} -> {:halt, {Enum.take(hits, @remote_limit), :ok}}
        {:error, reason} -> {:halt, {[], status_for(reason)}}
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

  defp crypto_candidates(query) do
    case cached_crypto_search(query) do
      {:ok, hits} ->
        candidates =
          for %{source_id: source_id, symbol: symbol, name: name} <-
                Enum.take(hits, @remote_limit) do
            %Candidate{
              kind: :crypto,
              symbol: symbol,
              name: name,
              quote_currency: "EUR",
              price_source: :coingecko,
              source_id: source_id
            }
          end

        {candidates, :ok}

      {:error, reason} ->
        {[], status_for(reason)}
    end
  end

  defp merge_results({hits, status}, {more, more_status}),
    do: {hits ++ more, worst_status([status, more_status])}

  defp status_for(:rate_limited), do: :rate_limited
  defp status_for(_reason), do: :unavailable

  defp worst_status(statuses) do
    cond do
      :rate_limited in statuses -> :rate_limited
      :unavailable in statuses -> :unavailable
      true -> :ok
    end
  end

  defp stamp(hits, identifier), do: Enum.map(hits, &Map.merge(&1, Map.new(identifier)))

  defp enrich_equities(hits) do
    hits
    |> Enum.uniq_by(& &1.symbol)
    |> Enum.take(@remote_limit)
    |> Task.async_stream(&enrich_equity/1,
      max_concurrency: @enrich_concurrency,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, candidate} -> candidate end)
  end

  defp enrich_equity(hit) do
    %{symbol: symbol, name: name, exchange: exchange, kind: kind} = hit

    candidate = %Candidate{
      kind: kind,
      symbol: symbol,
      name: name,
      exchange: exchange,
      price_source: :yahoo,
      source_id: symbol,
      isin: hit[:isin],
      wkn: hit[:wkn]
    }

    case cached_quote_meta(symbol) do
      {:ok, %{currency: currency, exchange: full_exchange}} ->
        %{candidate | quote_currency: currency, exchange: full_exchange || exchange}

      {:error, _reason} ->
        candidate
    end
  end

  # Every remote lookup goes through the cache: the equity provider's search
  # endpoint is rate-limited per IP, and instrument metadata barely changes.
  defp cached_search(query) do
    SearchCache.fetch({:equity_search, query}, ttls(), fn -> equity_client().search(query) end)
  end

  defp cached_crypto_search(query) do
    SearchCache.fetch({:crypto_search, query}, ttls(), fn -> crypto_client().search(query) end)
  end

  defp cached_lookup(id_type, value) do
    SearchCache.fetch({:security_id, id_type, value}, ttls(), fn ->
      security_id_client().lookup(id_type, value)
    end)
  end

  defp cached_quote_meta(symbol) do
    SearchCache.fetch({:quote_meta, symbol}, ttls(), fn -> equity_client().quote_meta(symbol) end)
  end

  defp ttls do
    config = Application.get_env(:folio, :search_cache)

    %{ok: config[:ok_ttl_ms], error: config[:error_ttl_ms]}
  end

  defp base_symbol(symbol), do: symbol |> String.split(".") |> hd()

  defp crypto_client, do: Application.get_env(:folio, :clients)[:crypto]
  defp equity_client, do: Application.get_env(:folio, :clients)[:equity]
  defp security_id_client, do: Application.get_env(:folio, :clients)[:security_id]
end
