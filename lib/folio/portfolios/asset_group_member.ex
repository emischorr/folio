defmodule Folio.Portfolios.AssetGroupMember do
  @moduledoc """
  Join row assigning one asset to one group within a portfolio. `portfolio_id`
  is denormalized from the group (see the migration) purely to let
  `[:portfolio_id, :asset_id]` enforce "one group per asset per portfolio" -
  it is never cast, only ever set by `Folio.Portfolios.assign_asset_to_group/3`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "asset_group_members" do
    belongs_to :asset_group, Folio.Portfolios.AssetGroup
    belongs_to :portfolio, Folio.Portfolios.Portfolio
    belongs_to :asset, Folio.Assets.Asset

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for a group assignment; all ids are set by the context."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(member, attrs) do
    member
    |> cast(attrs, [])
    |> validate_required([:asset_group_id, :portfolio_id, :asset_id])
    |> unique_constraint(:asset_id, name: :asset_group_members_portfolio_id_asset_id_index)
    |> foreign_key_constraint(:asset_group_id)
    |> foreign_key_constraint(:portfolio_id)
    |> foreign_key_constraint(:asset_id)
  end
end
