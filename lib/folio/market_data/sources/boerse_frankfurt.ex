defmodule Folio.MarketData.Sources.BoerseFrankfurt do
  @moduledoc """
  Börse Frankfurt quote endpoint - keyless, ISIN + MIC native.

  `api.boerse-frankfurt.de/v1/data/quote_box/single` answers without the
  MD5 trace headers older community docs describe (verified 2026-08-27) and
  quotes the actual listing for XETR and XFRA. The history endpoints
  currently return an empty object regardless of headers, so this source
  implements Quote only; see README "External data sources".
  """

  @behaviour Folio.MarketData.Sources.Source
  @behaviour Folio.MarketData.Sources.Quote

  import Folio.MarketData.Sources.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  alias Folio.MarketData.Markets

  @base_url "https://api.boerse-frankfurt.de/v1"
  @mics ["XETR", "XFRA"]

  @impl Folio.MarketData.Sources.Source
  def supports?(%{kind: kind, isin: isin, mic: mic}) do
    kind != :crypto and is_binary(isin) and mic in @mics
  end

  @impl Folio.MarketData.Sources.Quote
  def fetch_quote(%{isin: isin, mic: mic}) do
    with {:ok, body} <-
           [url: @base_url <> "/data/quote_box/single", params: [isin: isin, mic: mic]]
           |> base()
           |> Req.request()
           |> handle() do
      quote_from(body, mic)
    end
  end

  defp quote_from(%{"lastPrice" => last}, mic) when not is_nil(last) do
    price = to_decimal(last)

    if Decimal.positive?(price) do
      {:ok, %{price: price, at: DateTime.utc_now(), currency: Markets.currency(mic)}}
    else
      {:error, :no_quote}
    end
  end

  defp quote_from(body, _mic) when is_map(body), do: {:error, :no_quote}
  defp quote_from(_body, _mic), do: {:error, :unexpected_response}
end
