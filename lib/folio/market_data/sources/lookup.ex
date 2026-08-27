defmodule Folio.MarketData.Sources.Lookup do
  @moduledoc """
  Behaviour for turning user input into candidate listings.

  Used only when adding an asset. Securities candidates carry vendor-neutral
  identity fields; whatever provider code the source received is mapped to a
  MIC inside the source. Candidates whose venue cannot be mapped to a MIC are
  dropped by the source, not surfaced.
  """

  @type input :: {:isin, String.t()} | {:wkn, String.t()} | {:text, String.t()}

  @type security_candidate :: %{
          kind: :stock | :etf,
          isin: String.t() | nil,
          mic: String.t() | nil,
          ticker: String.t() | nil,
          name: String.t(),
          quote_currency: String.t() | nil
        }

  @type crypto_candidate :: %{symbol: String.t(), name: String.t()}

  @type candidate :: security_candidate() | crypto_candidate()

  @doc "Candidate listings for the input; an empty list is a valid answer."
  @callback lookup(input()) :: {:ok, [candidate()]} | {:error, term()}
end
