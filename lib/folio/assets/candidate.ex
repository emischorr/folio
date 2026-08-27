defmodule Folio.Assets.Candidate do
  @moduledoc """
  A resolver result the UI can present, e.g. "SPYY · Xetra · EUR". Carries
  only vendor-neutral identity, so choosing a candidate can create an asset
  directly. `local_asset_id` is set when the asset already exists locally.
  """

  alias Folio.Assets.Asset

  defstruct [
    :kind,
    :symbol,
    :ticker,
    :name,
    :isin,
    :mic,
    :quote_currency,
    :local_asset_id
  ]

  @type t :: %__MODULE__{
          kind: Asset.kind(),
          symbol: String.t() | nil,
          ticker: String.t() | nil,
          name: String.t(),
          isin: String.t() | nil,
          mic: String.t() | nil,
          quote_currency: String.t() | nil,
          local_asset_id: pos_integer() | nil
        }

  @doc "Builds a candidate from an existing local asset."
  @spec from_asset(Asset.t()) :: t()
  def from_asset(%Asset{} = asset) do
    %__MODULE__{
      kind: asset.kind,
      symbol: asset.symbol,
      ticker: asset.ticker,
      name: asset.name,
      isin: asset.isin,
      mic: asset.mic,
      quote_currency: asset.quote_currency,
      local_asset_id: asset.id
    }
  end

  @doc "The user-facing code: exchange ticker, or symbol for crypto."
  @spec display_code(t()) :: String.t() | nil
  def display_code(%__MODULE__{ticker: ticker, symbol: symbol}), do: ticker || symbol

  @doc "The identity a candidate stands for, used to dedupe local vs remote hits."
  @spec identity(t()) :: term()
  def identity(%__MODULE__{kind: :crypto, symbol: symbol}), do: {:crypto, symbol}

  def identity(%__MODULE__{isin: isin, mic: mic, ticker: ticker}),
    do: {:security, isin, mic, ticker}

  @doc "Attributes for `Folio.Assets.create_asset/1`."
  @spec to_attrs(t()) :: map()
  def to_attrs(%__MODULE__{} = candidate) do
    candidate
    |> Map.from_struct()
    |> Map.delete(:local_asset_id)
  end
end
