defmodule Folio.Assets.Resolver do
  @moduledoc """
  Turns a user-typed query into asset candidates: local matches first, then
  the market-data Lookup chains.

  The query is classified first. An ISIN goes to the security chain as an
  identifier; a WKN goes as an identifier and, because six characters may
  just as well be a ticker, additionally as free text; plain text is searched
  as securities and as crypto. The resolver knows no sources - which
  providers answer, in what order, and how their venues map to MICs is
  `Folio.MarketData`'s concern. Remote outages degrade to local-only results
  with a non-`:ok` status so the UI can say so.
  """

  alias Folio.Assets
  alias Folio.Assets.Candidate
  alias Folio.Assets.Identifier
  alias Folio.MarketData

  # Crypto lookups do not report a quote currency; the portfolio's base
  # currency is the sensible default and stays editable on the form.
  @crypto_currency "EUR"

  @typedoc "Health of the remote lookups consulted for a query."
  @type status :: :ok | :rate_limited | :unavailable

  @doc """
  Resolves a query into an ordered candidate list (local first) plus the
  health of the remote lookups, so the UI can tell "nothing matched" apart
  from "the provider refused to answer".
  """
  @spec resolve(String.t()) :: %{candidates: [Candidate.t()], status: status()}
  def resolve(query) do
    local = query |> Assets.search_local() |> Enum.map(&Candidate.from_asset/1)
    known = MapSet.new(local, &Candidate.identity/1)

    {hits, status} = query |> Identifier.classify() |> remote_candidates(query)

    remote =
      hits
      |> Enum.uniq_by(&Candidate.identity/1)
      |> Enum.reject(&MapSet.member?(known, Candidate.identity(&1)))

    %{candidates: local ++ remote, status: status}
  end

  defp remote_candidates({:isin, isin}, _query) do
    security_lookup({:isin, isin})
  end

  defp remote_candidates({:wkn, wkn}, query) do
    merge_lookups([
      security_lookup({:wkn, wkn}),
      security_lookup({:text, query}),
      crypto_lookup(query)
    ])
  end

  defp remote_candidates(:text, query) do
    merge_lookups([crypto_lookup(query), security_lookup({:text, query})])
  end

  defp security_lookup(input) do
    case MarketData.lookup(:security, input) do
      {:ok, hits} -> {Enum.map(hits, &security_candidate/1), :ok}
      {:error, reason} -> {[], status_for(reason)}
    end
  end

  defp crypto_lookup(query) do
    case MarketData.lookup(:crypto, query) do
      {:ok, hits} -> {Enum.map(hits, &crypto_candidate/1), :ok}
      {:error, reason} -> {[], status_for(reason)}
    end
  end

  defp security_candidate(hit) do
    %Candidate{
      kind: hit.kind,
      ticker: hit.ticker,
      name: hit.name,
      isin: hit.isin,
      mic: hit.mic,
      quote_currency: hit.quote_currency
    }
  end

  defp crypto_candidate(%{symbol: symbol, name: name}) do
    %Candidate{kind: :crypto, symbol: symbol, name: name, quote_currency: @crypto_currency}
  end

  defp merge_lookups(lookups) do
    {candidate_lists, statuses} = Enum.unzip(lookups)
    {Enum.concat(candidate_lists), worst_status(statuses)}
  end

  # An unsupported input is not an outage - the chain simply has no source
  # for it (e.g. crypto lookups for an ISIN).
  defp status_for(:unsupported), do: :ok
  defp status_for(:rate_limited), do: :rate_limited
  defp status_for(_reason), do: :unavailable

  defp worst_status(statuses) do
    Enum.find(statuses, &(&1 == :rate_limited)) || Enum.find(statuses, &(&1 == :unavailable)) ||
      :ok
  end
end
