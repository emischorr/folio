defmodule Folio.Repo.Migrations.CreatePortfolios do
  use Ecto.Migration

  def change do
    create table(:portfolios) do
      add :name, :string, null: false
      add :base_currency, :string, null: false, default: "EUR"

      timestamps(type: :utc_datetime)
    end
  end
end
