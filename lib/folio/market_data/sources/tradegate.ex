defmodule Folio.MarketData.Sources.Tradegate do
  @moduledoc """
  Tradegate quote endpoint - keyless, ISIN-native, EUR-denominated.

  `https://www.tradegate.de/refresh.php` 301s to `www.tradegatebsx.com`
  (verified 2026-08-27); we call the final host directly. The price is
  Tradegate's own venue price, used as a delayed proxy for the asset's
  listing - acceptable for EUR-quoted securities a German retail investor
  trades, which is exactly what `supports?/1` claims. Pre-open the endpoint
  reports `last: 0`; that is "no quote yet", not a price.
  """

  @behaviour Folio.MarketData.Sources.Source
  @behaviour Folio.MarketData.Sources.Quote

  import Folio.MarketData.Sources.HTTP, only: [base: 1, handle: 1, to_decimal: 1]

  alias Folio.MarketData.Markets

  @url "https://www.tradegatebsx.com/refresh.php"
  @extra_mics ["XAMS", "XPAR", "XMIL", "XWBO"]

  @impl Folio.MarketData.Sources.Source
  def supports?(%{kind: kind, isin: isin, quote_currency: currency, mic: mic}) do
    kind != :crypto and is_binary(isin) and currency == "EUR" and
      mic in (Markets.german_retail_mics() ++ @extra_mics)
  end

  @impl Folio.MarketData.Sources.Quote
  def fetch_quote(%{isin: isin}) do
    with {:ok, body} <-
           [url: @url, params: [isin: isin]] |> base() |> Req.request() |> handle() do
      quote_from(body)
    end
  end

  defp quote_from(body) when is_map(body) do
    case positive_price(body["last"]) || positive_price(body["close"]) do
      nil -> {:error, :no_quote}
      price -> {:ok, %{price: price, at: DateTime.utc_now(), currency: "EUR"}}
    end
  end

  defp quote_from(_body), do: {:error, :unexpected_response}

  defp positive_price(nil), do: nil

  defp positive_price(value) do
    price = to_decimal(value)
    if Decimal.positive?(price), do: price
  end
end
