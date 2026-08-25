defmodule Folio.MarketData.FxRate do
  @moduledoc """
  Daily EUR-pivot exchange rate: one row means 1 EUR = `rate` × `currency`.
  Cross rates are derived through EUR.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "fx_rates" do
    field :date, :date
    field :currency, :string
    field :rate, :decimal
  end
end
