defmodule Folio.Assets.Resolver do
  @moduledoc """
  Turns a user-typed name or ticker into asset candidates: local matches
  first, then remote search (CoinGecko for crypto, the equity client for
  stocks/ETFs). Equity search results carry no currency, so the top hits are
  enriched through `quote_meta/1`; enrichment failures leave the currency nil
  rather than dropping the hit. Remote outages degrade to local-only results.
  """

  alias Folio.Assets
  alias Folio.Assets.Candidate

  @remote_limit 5

  @doc "Resolves a query into an ordered candidate list (local first)."
  @spec resolve(String.t()) :: [Candidate.t()]
  def resolve(query) do
    local = query |> Assets.search_local() |> Enum.map(&Candidate.from_asset/1)
    known = MapSet.new(local, &{&1.price_source, &1.source_id})
    remote = crypto_candidates(query) ++ equity_candidates(query)

    local ++ Enum.reject(remote, &MapSet.member?(known, {&1.price_source, &1.source_id}))
  end

  defp crypto_candidates(query) do
    case crypto_client().search(query) do
      {:ok, hits} ->
        for %{source_id: source_id, symbol: symbol, name: name} <- Enum.take(hits, @remote_limit) do
          %Candidate{
            kind: :crypto,
            symbol: symbol,
            name: name,
            quote_currency: "EUR",
            price_source: :coingecko,
            source_id: source_id
          }
        end

      {:error, _reason} ->
        []
    end
  end

  defp equity_candidates(query) do
    case equity_client().search(query) do
      {:ok, hits} -> hits |> Enum.take(@remote_limit) |> Enum.map(&enrich_equity/1)
      {:error, _reason} -> []
    end
  end

  defp enrich_equity(%{symbol: symbol, name: name, exchange: exchange, kind: kind}) do
    candidate = %Candidate{
      kind: kind,
      symbol: symbol,
      name: name,
      exchange: exchange,
      price_source: :yahoo,
      source_id: symbol
    }

    case equity_client().quote_meta(symbol) do
      {:ok, %{currency: currency, exchange: full_exchange}} ->
        %{candidate | quote_currency: currency, exchange: full_exchange || exchange}

      {:error, _reason} ->
        candidate
    end
  end

  defp crypto_client, do: Application.get_env(:folio, :clients)[:crypto]
  defp equity_client, do: Application.get_env(:folio, :clients)[:equity]
end
