defmodule Folio.MarketData.Sources.Source do
  @moduledoc """
  Coverage declaration shared by every market-data source.

  `supports?/1` receives whatever the chain is about to hand the source: a
  `Folio.MarketData.Sources.Lookup.input()` tuple for lookups, or a
  `Folio.MarketData.Listing.t()` for history and quotes. A source answers
  honestly for the shapes it serves; the chain skips unsupported sources
  silently instead of discovering coverage through errors.

  Declared once here rather than on each concern behaviour so a module can
  implement several concerns without conflicting callback definitions.
  """

  alias Folio.MarketData.Listing
  alias Folio.MarketData.Sources.Lookup

  @callback supports?(Lookup.input() | Listing.t()) :: boolean()
end
