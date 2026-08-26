defmodule Folio.Clients.SecurityIdClient do
  @moduledoc """
  Resolves a security identifier (ISIN, WKN) into the tickers it is listed
  under. Deliberately narrow: identifier providers rarely carry prices, and
  price providers rarely carry identifiers.
  """

  @type id_type :: :isin | :wkn
  @type id_hit :: %{ticker: String.t(), exchange_code: String.t() | nil, name: String.t() | nil}

  @callback lookup(id_type :: id_type(), value :: String.t()) ::
              {:ok, [id_hit()]} | {:error, term()}
end
