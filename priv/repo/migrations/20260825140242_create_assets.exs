defmodule Folio.Repo.Migrations.CreateAssets do
  use Ecto.Migration

  def change do
    create table(:assets) do
      add :symbol, :string, null: false
      add :name, :string, null: false
      add :kind, :string, null: false
      add :exchange, :string
      add :quote_currency, :string, null: false
      add :price_source, :string, null: false
      add :source_id, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:assets, [:price_source, :source_id])
    create index(:assets, [:symbol])
  end
end
