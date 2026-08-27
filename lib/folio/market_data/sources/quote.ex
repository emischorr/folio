defmodule Folio.MarketData.Sources.Quote do
  @moduledoc """
  Behaviour for the latest (possibly delayed) price of a listing.

  Used by the periodic refresh. `fetch_quotes/1` is an optional batch variant;
  the chain uses it when the source exports it, so a source with a batched
  provider endpoint (e.g. CoinGecko's simple/price) can answer one HTTP call
  for many listings.
  """

  alias Folio.MarketData.Listing

  @type quote_result :: %{
          price: Decimal.t(),
          at: DateTime.t() | nil,
          currency: String.t() | nil
        }

  @doc "The latest price for one listing."
  @callback fetch_quote(Listing.t()) :: {:ok, quote_result()} | {:error, term()}

  @doc "Batch variant, keyed by asset id; listings the source cannot answer are omitted."
  @callback fetch_quotes([Listing.t()]) ::
              {:ok, %{(asset_id :: pos_integer()) => quote_result()}} | {:error, term()}

  @optional_callbacks fetch_quotes: 1
end
