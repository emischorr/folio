defmodule Folio.Analytics.Dataset do
  @moduledoc """
  The plain-data input to `Folio.Analytics.Engine`: no Ecto structs, so
  engine tests build these by hand.

  - `assets`: `%{asset_id => %{symbol, name, quote_currency}}`
  - `txns`: ascending by `executed_at`, each
    `%{asset_id, type, executed_at, quantity, price_per_unit, fee, currency}`
  - `prices`: `%{asset_id => [{DateTime, Decimal}]}`, DESCENDING
  - `fx`: `%{currency => [{DateTime, Decimal}]}`, DESCENDING - daily EUR-pivot
    rates timestamped at midnight UTC of their date
  """

  defstruct base_currency: "EUR", assets: %{}, txns: [], prices: %{}, fx: %{}

  @type t :: %__MODULE__{
          base_currency: String.t(),
          assets: %{pos_integer() => map()},
          txns: [map()],
          prices: %{pos_integer() => Folio.Analytics.Lookup.series()},
          fx: %{String.t() => Folio.Analytics.Lookup.series()}
        }

  @doc "Restricts the dataset to a single asset (for per-asset series)."
  @spec scope_to_asset(t(), pos_integer()) :: t()
  def scope_to_asset(%__MODULE__{} = dataset, asset_id) do
    %{
      dataset
      | assets: Map.take(dataset.assets, [asset_id]),
        txns: Enum.filter(dataset.txns, &(&1.asset_id == asset_id)),
        prices: Map.take(dataset.prices, [asset_id])
    }
  end
end
