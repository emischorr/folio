defmodule Folio.Repo.Migrations.CreatePortfolioMembers do
  use Ecto.Migration

  def change do
    create table(:portfolio_members) do
      add :portfolio_id, references(:portfolios, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:portfolio_members, [:portfolio_id, :user_id])
    create index(:portfolio_members, [:user_id])
  end
end
