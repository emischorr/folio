defmodule Folio.Portfolios.Transaction do
  @moduledoc """
  A manually entered trade. `quantity` is always positive; direction lives in
  `type`. The enum is a string column, so future types (`dividend`, `reward`,
  `transfer`) are a schema-only change. `source`/`external_id` allow a future
  import to stay idempotent.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type type :: :buy | :sell

  schema "transactions" do
    field :type, Ecto.Enum, values: [:buy, :sell]
    field :executed_at, :utc_datetime
    field :quantity, :decimal
    field :price_per_unit, :decimal
    field :fee, :decimal, default: Decimal.new(0)
    field :currency, :string
    field :source, :string
    field :external_id, :string

    belongs_to :portfolio, Folio.Portfolios.Portfolio
    belongs_to :asset, Folio.Assets.Asset

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a transaction; `portfolio_id` is set by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(transaction, attrs) do
    transaction
    |> cast(attrs, [
      :asset_id,
      :type,
      :executed_at,
      :quantity,
      :price_per_unit,
      :fee,
      :currency,
      :source,
      :external_id
    ])
    |> validate_required([:asset_id, :type, :executed_at, :quantity, :price_per_unit])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:price_per_unit, greater_than_or_equal_to: 0)
    |> validate_number(:fee, greater_than_or_equal_to: 0)
    |> validate_format(:currency, ~r/^[A-Z]{3}$/)
    |> check_constraint(:quantity, name: :quantity_positive)
    |> unique_constraint([:source, :external_id])
    |> foreign_key_constraint(:portfolio_id)
    |> foreign_key_constraint(:asset_id)
  end
end
