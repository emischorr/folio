defmodule Folio.Assets.Candidate do
  @moduledoc """
  A resolver result the UI can present, e.g. "NVIDIA Corporation · NASDAQ ·
  USD". Carries the technical source mapping so choosing a candidate can
  create an asset directly. `local_asset_id` is set when the asset already
  exists locally.
  """

  alias Folio.Assets.Asset

  defstruct [
    :kind,
    :symbol,
    :name,
    :exchange,
    :quote_currency,
    :price_source,
    :source_id,
    :local_asset_id
  ]

  @type t :: %__MODULE__{
          kind: Asset.kind(),
          symbol: String.t(),
          name: String.t(),
          exchange: String.t() | nil,
          quote_currency: String.t() | nil,
          price_source: Asset.price_source(),
          source_id: String.t(),
          local_asset_id: pos_integer() | nil
        }

  @doc "Builds a candidate from an existing local asset."
  @spec from_asset(Asset.t()) :: t()
  def from_asset(%Asset{} = asset) do
    %__MODULE__{
      kind: asset.kind,
      symbol: asset.symbol,
      name: asset.name,
      exchange: asset.exchange,
      quote_currency: asset.quote_currency,
      price_source: asset.price_source,
      source_id: asset.source_id,
      local_asset_id: asset.id
    }
  end

  @doc ~S(Display label like "NVIDIA Corporation · NASDAQ · USD".)
  @spec label(t()) :: String.t()
  def label(%__MODULE__{name: name, exchange: exchange, quote_currency: quote_currency}) do
    [name, exchange, quote_currency]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "Attributes for `Folio.Assets.create_asset/1`."
  @spec to_attrs(t()) :: map()
  def to_attrs(%__MODULE__{} = candidate) do
    candidate
    |> Map.from_struct()
    |> Map.delete(:local_asset_id)
  end
end
