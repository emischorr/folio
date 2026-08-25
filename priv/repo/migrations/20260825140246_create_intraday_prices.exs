defmodule Folio.Repo.Migrations.CreateIntradayPrices do
  use Ecto.Migration

  def change do
    create table(:intraday_prices) do
      add :asset_id, references(:assets, on_delete: :delete_all), null: false
      add :at, :utc_datetime, null: false
      add :price, :decimal, null: false
    end

    create unique_index(:intraday_prices, [:asset_id, :at])
    create index(:intraday_prices, [:at])
  end
end
