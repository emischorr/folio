defmodule Folio.MarketData.Sources.OpenFigi do
  @moduledoc """
  OpenFIGI mapping API - the Lookup source for security identifiers.

  Keyless (25 requests/minute per IP); an API key (`OPEN_FIGI_KEY`) raises
  the limit. Maps ISIN and WKN (`ID_WERTPAPIER`) to per-venue listings. Two
  honest limitations: it never returns an identifier, so a WKN lookup yields
  candidates without an ISIN (the user supplies it before creating the
  asset), and its exchange codes are Bloomberg codes, not MICs - the mapping
  table below lives here, in the source, and unmappable codes drop the
  record.
  """

  @behaviour Folio.MarketData.Sources.Source
  @behaviour Folio.MarketData.Sources.Lookup

  import Folio.MarketData.Sources.HTTP, only: [base: 1, handle: 1]

  require Logger

  @base_url "https://api.openfigi.com/v3"
  @id_types %{isin: "ID_ISIN", wkn: "ID_WERTPAPIER"}

  # Bloomberg exchange code -> ISO 10383 MIC. "GR" is the German composite,
  # which for the venues we track is the Xetra listing.
  @exch_code_to_mic %{
    "GR" => "XETR",
    "GY" => "XETR",
    "GF" => "XFRA",
    "GS" => "XSTU",
    "GM" => "XMUN",
    "GB" => "XBER",
    "GD" => "XDUS",
    "GH" => "XHAM",
    "GI" => "XHAN",
    "GT" => "XGAT",
    "LN" => "XLON",
    "NA" => "XAMS",
    "FP" => "XPAR",
    "IM" => "XMIL",
    "SE" => "XSWX",
    "SW" => "XSWX",
    "AV" => "XWBO",
    "UW" => "XNAS",
    "UQ" => "XNAS",
    "UN" => "XNYS",
    "UP" => "ARCX",
    "CN" => "XTSE",
    "CT" => "XTSE",
    "HK" => "XHKG"
  }

  @etf_security_types ["ETP", "ETF"]
  @etf_security_types2 ["Mutual Fund", "ETF"]

  @impl Folio.MarketData.Sources.Source
  def supports?({:isin, _value}), do: true
  def supports?({:wkn, _value}), do: true
  def supports?({:text, _query}), do: false

  @impl Folio.MarketData.Sources.Lookup
  def lookup({id_type, value}) do
    payload = [%{idType: @id_types[id_type], idValue: value}]

    with {:ok, body} <- request(payload) do
      {:ok, candidates(body, known_isin(id_type, value))}
    end
  end

  defp known_isin(:isin, value), do: value
  defp known_isin(:wkn, _value), do: nil

  # One result object per query item; we always send exactly one.
  defp candidates([%{"data" => records} | _rest], isin) when is_list(records) do
    records
    |> Enum.filter(&equity_with_ticker?/1)
    |> Enum.flat_map(&to_candidate(&1, isin))
    |> Enum.uniq_by(&{&1.ticker, &1.mic})
  end

  # `[%{"warning" => "No identifier found."}]` for an unknown identifier.
  defp candidates(_body, _isin), do: []

  defp equity_with_ticker?(record) do
    is_binary(record["ticker"]) and record["marketSector"] in ["Equity", nil]
  end

  defp to_candidate(record, isin) do
    case Map.get(@exch_code_to_mic, record["exchCode"]) do
      nil ->
        Logger.debug("OpenFIGI record dropped: unmapped exchCode #{inspect(record["exchCode"])}")
        []

      mic ->
        [
          %{
            kind: kind(record),
            isin: isin,
            mic: mic,
            ticker: record["ticker"],
            name: record["name"] || record["ticker"],
            quote_currency: Folio.MarketData.Markets.currency(mic)
          }
        ]
    end
  end

  defp kind(record) do
    if record["securityType"] in @etf_security_types or
         record["securityType2"] in @etf_security_types2,
       do: :etf,
       else: :stock
  end

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
