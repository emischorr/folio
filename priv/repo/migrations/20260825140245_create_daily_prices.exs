defmodule Folio.Repo.Migrations.CreateDailyPrices do
  use Ecto.Migration

  def change do
    create table(:daily_prices) do
      add :asset_id, references(:assets, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :price, :decimal, null: false
    end

    create unique_index(:daily_prices, [:asset_id, :date])
  end
end
