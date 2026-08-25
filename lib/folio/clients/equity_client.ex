defmodule Folio.Clients.EquityClient do
  @moduledoc """
  Provider-agnostic stock/ETF market data. Implementations take plain values
  and return atom-keyed maps with `Decimal` prices. The active implementation
  is `Application.get_env(:folio, :clients)[:equity]`.
  """

  @typedoc """
  Search hit: symbol, display name, exchange, and `:stock`/`:etf` kind.
  Quote currency is NOT part of search results (Yahoo omits it) - fetch it
  via `quote_meta/1`.
  """
  @type search_hit :: %{
          symbol: String.t(),
          name: String.t(),
          exchange: String.t() | nil,
          kind: :stock | :etf
        }

  @callback search(query :: String.t()) :: {:ok, [search_hit()]} | {:error, term()}

  @callback quote_meta(symbol :: String.t()) ::
              {:ok, %{currency: String.t(), exchange: String.t() | nil, price: Decimal.t()}}
              | {:error, term()}

  @callback daily_history(symbol :: String.t(), from :: Date.t()) ::
              {:ok, [%{date: Date.t(), price: Decimal.t()}]} | {:error, term()}
end
