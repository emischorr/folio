defmodule Folio.Clients.CryptoClient do
  @moduledoc """
  Provider-agnostic crypto market data. Implementations take plain values and
  return atom-keyed maps with `Decimal` prices. The active implementation is
  `Application.get_env(:folio, :clients)[:crypto]`.
  """

  @typedoc "Search hit: `%{source_id: String.t(), symbol: String.t(), name: String.t()}`"
  @type search_hit :: %{source_id: String.t(), symbol: String.t(), name: String.t()}

  @callback search(query :: String.t()) :: {:ok, [search_hit()]} | {:error, term()}

  @callback daily_history(
              source_id :: String.t(),
              vs_currency :: String.t(),
              days :: pos_integer()
            ) ::
              {:ok, [%{date: Date.t(), price: Decimal.t()}]} | {:error, term()}

  @callback current_prices(source_ids :: [String.t()], vs_currency :: String.t()) ::
              {:ok, %{String.t() => Decimal.t()}} | {:error, term()}
end
