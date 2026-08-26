defmodule Folio.Repo.Migrations.AddIdentifiersToAssets do
  use Ecto.Migration

  def change do
    alter table(:assets) do
      add :isin, :string
      add :wkn, :string
    end

    # Not unique: one ISIN has many listings (IUIT.L and QDVE.DE are the same
    # fund in different currencies) and both may legitimately be tracked.
    create index(:assets, [:isin])
  end
end
