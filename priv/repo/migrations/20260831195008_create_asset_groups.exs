defmodule Folio.Repo.Migrations.CreateAssetGroups do
  @moduledoc "Named, portfolio-scoped containers for holdings display grouping."

  use Ecto.Migration

  def change do
    create table(:asset_groups) do
      add :portfolio_id, references(:portfolios, on_delete: :delete_all), null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:asset_groups, [:portfolio_id, :name])
  end
end
