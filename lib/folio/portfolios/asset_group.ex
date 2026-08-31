defmodule Folio.Portfolios.AssetGroup do
  @moduledoc """
  A named, portfolio-scoped container assets can be assigned to for display
  grouping on the dashboard. Purely presentational - carries no financial data.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "asset_groups" do
    field :name, :string

    belongs_to :portfolio, Folio.Portfolios.Portfolio

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating or renaming a group; `portfolio_id` is set by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(asset_group, attrs) do
    asset_group
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 120)
    |> unique_constraint(:name, name: :asset_groups_portfolio_id_name_index)
    |> foreign_key_constraint(:portfolio_id)
  end
end
