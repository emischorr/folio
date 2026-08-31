defmodule Folio.Portfolios.Portfolio do
  @moduledoc """
  A collection of transactions with a base currency. Ownership and sharing are
  expressed through `Folio.Portfolios.PortfolioMember` roles, not columns here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "portfolios" do
    field :name, :string
    field :base_currency, :string, default: "EUR"

    has_many :members, Folio.Portfolios.PortfolioMember
    has_many :transactions, Folio.Portfolios.Transaction
    has_many :asset_groups, Folio.Portfolios.AssetGroup

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or renaming a portfolio."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(portfolio, attrs) do
    portfolio
    |> cast(attrs, [:name, :base_currency])
    |> validate_required([:name, :base_currency])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_format(:base_currency, ~r/^[A-Z]{3}$/)
  end
end
