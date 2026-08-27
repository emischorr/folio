defmodule Folio.MarketData.Listing do
  @moduledoc """
  Vendor-neutral description of a tradable listing, as passed to sources.

  A plain map, deliberately not an Ecto schema: it is the only asset shape
  that crosses the market-data boundary, so sources never see `Folio.Assets`
  internals. Securities are identified by ISIN + MIC with an exchange-local
  ticker; crypto by symbol. Each source builds whatever provider identifier
  it needs from these general fields.
  """

  @type t :: %{
          asset_id: pos_integer() | nil,
          kind: :crypto | :stock | :etf,
          symbol: String.t() | nil,
          ticker: String.t() | nil,
          isin: String.t() | nil,
          mic: String.t() | nil,
          quote_currency: String.t()
        }

  @doc "Builds a listing, requiring kind and quote currency; the rest defaults to nil."
  @spec new(map()) :: t()
  def new(%{kind: kind, quote_currency: quote_currency} = fields) do
    %{
      asset_id: Map.get(fields, :asset_id),
      kind: kind,
      symbol: Map.get(fields, :symbol),
      ticker: Map.get(fields, :ticker),
      isin: Map.get(fields, :isin),
      mic: Map.get(fields, :mic),
      quote_currency: quote_currency
    }
  end
end
