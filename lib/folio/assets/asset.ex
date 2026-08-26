defmodule Folio.Assets.Asset do
  @moduledoc """
  A globally shared, tradable instrument. Different listings of the same
  company (NASDAQ vs Xetra) are different assets with different price series.
  `price_source`/`source_id` are technical fetch fields, never user-entered.
  `isin`/`wkn` are optional: no price provider returns them, so they are only
  known when the user searched by identifier or typed one in.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Folio.Assets.Identifier

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
    field :isin, :string
    field :wkn, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating an asset from resolver output or manual entry."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :symbol,
      :name,
      :kind,
      :exchange,
      :quote_currency,
      :price_source,
      :source_id,
      :isin,
      :wkn
    ])
    |> validate_required([:symbol, :name, :kind, :quote_currency, :price_source, :source_id])
    |> update_change(:quote_currency, &String.upcase/1)
    |> validate_format(:quote_currency, ~r/^[A-Z]{3}$/)
    |> identifier_changeset()
    |> unique_constraint([:price_source, :source_id])
  end

  @doc "Changeset for filling in identifiers on an existing asset."
  @spec identifiers_changeset(t(), map()) :: Ecto.Changeset.t()
  def identifiers_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:isin, :wkn])
    |> identifier_changeset()
  end

  defp identifier_changeset(changeset) do
    changeset
    |> update_change(:isin, &Identifier.normalize/1)
    |> update_change(:wkn, &Identifier.normalize/1)
    |> validate_change(:isin, fn field, value ->
      if Identifier.isin?(value), do: [], else: [{field, "is not a valid ISIN"}]
    end)
    |> validate_change(:wkn, fn field, value ->
      if Identifier.wkn?(value), do: [], else: [{field, "is not a valid WKN"}]
    end)
  end
end
