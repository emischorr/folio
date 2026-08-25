defmodule Folio.Assets.Asset do
  @moduledoc """
  A globally shared, tradable instrument. Different listings of the same
  company (NASDAQ vs Xetra) are different assets with different price series.
  `price_source`/`source_id` are technical fetch fields, never user-entered.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type kind :: :crypto | :stock | :etf
  @type price_source :: :coingecko | :yahoo

  schema "assets" do
    field :symbol, :string
    field :name, :string
    field :kind, Ecto.Enum, values: [:crypto, :stock, :etf]
    field :exchange, :string
    field :quote_currency, :string
    field :price_source, Ecto.Enum, values: [:coingecko, :yahoo]
    field :source_id, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating an asset from resolver output or manual entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [:symbol, :name, :kind, :exchange, :quote_currency, :price_source, :source_id])
    |> validate_required([:symbol, :name, :kind, :quote_currency, :price_source, :source_id])
    |> update_change(:quote_currency, &String.upcase/1)
    |> validate_format(:quote_currency, ~r/^[A-Z]{3}$/)
    |> unique_constraint([:price_source, :source_id])
  end
end
