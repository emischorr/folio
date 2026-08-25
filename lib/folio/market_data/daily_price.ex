defmodule Folio.MarketData.DailyPrice do
  @moduledoc """
  One closing price per asset per day, in the asset's quote currency.
  Kept forever.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "daily_prices" do
    field :date, :date
    field :price, :decimal

    belongs_to :asset, Folio.Assets.Asset
  end
end
