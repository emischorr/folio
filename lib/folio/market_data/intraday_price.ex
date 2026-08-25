defmodule Folio.MarketData.IntradayPrice do
  @moduledoc """
  A raw price tick in the asset's quote currency. Pruned after about eight
  days by the nightly job; `daily_prices` keeps the long-term record.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "intraday_prices" do
    field :at, :utc_datetime
    field :price, :decimal

    belongs_to :asset, Folio.Assets.Asset
  end
end
