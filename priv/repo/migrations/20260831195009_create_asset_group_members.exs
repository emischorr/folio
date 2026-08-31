defmodule Folio.Repo.Migrations.CreateAssetGroupMembers do
  @moduledoc """
  Assigns an asset to a group within a portfolio. `portfolio_id` is
  denormalized from `asset_group_id` (Postgres can't express a unique
  constraint spanning two tables) so `[:portfolio_id, :asset_id]` can enforce
  "at most one group per asset per portfolio" directly.
  """

  use Ecto.Migration

  def change do
    create table(:asset_group_members) do
      add :asset_group_id, references(:asset_groups, on_delete: :delete_all), null: false
      add :portfolio_id, references(:portfolios, on_delete: :delete_all), null: false
      add :asset_id, references(:assets, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:asset_group_members, [:portfolio_id, :asset_id])
    create index(:asset_group_members, [:asset_group_id])
  end
end
