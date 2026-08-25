defmodule Folio.Repo.Migrations.CreateTransactions do
  use Ecto.Migration

  def change do
    create table(:transactions) do
      add :portfolio_id, references(:portfolios, on_delete: :delete_all), null: false
      add :asset_id, references(:assets, on_delete: :restrict), null: false
      add :type, :string, null: false
      add :executed_at, :utc_datetime, null: false
      add :quantity, :decimal, null: false
      add :price_per_unit, :decimal, null: false
      add :fee, :decimal, null: false, default: 0
      add :currency, :string, null: false
      add :source, :string
      add :external_id, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:transactions, [:source, :external_id],
             where: "source IS NOT NULL AND external_id IS NOT NULL"
           )

    create index(:transactions, [:portfolio_id, :executed_at])
    create index(:transactions, [:asset_id, :executed_at])
    create constraint(:transactions, :quantity_positive, check: "quantity > 0")
  end
end
