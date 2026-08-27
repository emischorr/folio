defmodule Folio.MarketData.Sources.History do
  @moduledoc """
  Behaviour for daily closes over a date range.

  Used by backfill and the nightly close - must be cheap and stable. Sources
  may return less than the requested range (provider caps); callers upsert
  whatever arrives.
  """

  alias Folio.MarketData.Listing

  @doc "Daily closes for the listing, ascending, within `[from, to]`."
  @callback daily_history(Listing.t(), from :: Date.t(), to :: Date.t()) ::
              {:ok, [%{date: Date.t(), price: Decimal.t()}]} | {:error, term()}
end
