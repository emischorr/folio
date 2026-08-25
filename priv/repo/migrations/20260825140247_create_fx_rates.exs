defmodule Folio.Repo.Migrations.CreateFxRates do
  use Ecto.Migration

  def change do
    create table(:fx_rates) do
      add :date, :date, null: false
      add :currency, :string, null: false
      add :rate, :decimal, null: false
    end

    create unique_index(:fx_rates, [:currency, :date])
  end
end
