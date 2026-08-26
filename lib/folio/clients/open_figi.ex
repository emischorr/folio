defmodule Folio.Clients.OpenFigi do
  @moduledoc """
  OpenFIGI mapping API. Keyless (25 requests/minute per IP); an
  `OPENFIGI_API_KEY` raises the limit. Maps ISIN and WKN to tickers - it
  never returns an identifier, so it cannot resolve a ticker back to its
  ISIN.
  """

  @behaviour Folio.Clients.SecurityIdClient

  import Folio.Clients.HTTP, only: [base: 1, handle: 1]

  @base_url "https://api.openfigi.com/v3"
  @id_types %{isin: "ID_ISIN", wkn: "ID_WERTPAPIER"}

  @impl true
  def lookup(id_type, value) when is_map_key(@id_types, id_type) do
    payload = [%{idType: @id_types[id_type], idValue: value}]

    with {:ok, body} <- request(payload) do
      {:ok, hits(body)}
    end
  end

  # One result object per query item; we always send exactly one.
  defp hits([%{"data" => records} | _rest]) when is_list(records) do
    records
    |> Enum.filter(&is_binary(&1["ticker"]))
    |> Enum.map(&%{ticker: &1["ticker"], exchange_code: &1["exchCode"], name: &1["name"]})
    |> Enum.uniq_by(& &1.ticker)
  end

  # `[%{"warning" => "No identifier found."}]` for an unknown identifier.
  defp hits(_body), do: []

  defp request(payload) do
    [url: @base_url <> "/mapping", method: :post, json: payload]
    |> Keyword.merge(headers: api_key_headers())
    |> base()
    |> Req.request()
    |> handle()
  end

  defp api_key_headers do
    case Application.get_env(:folio, :openfigi_api_key) do
      nil -> []
      key -> [{"x-openfigi-apikey", key}]
    end
  end
end
