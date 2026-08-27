defmodule Folio.Repo.Migrations.DropProviderFieldsFromAssets do
  @moduledoc """
  Second half of the vendor-neutral identity refactor: removes the vendor
  fetch fields and the WKN (search input only, never identity), and installs
  the new identity constraints - securities are unique per (isin, mic),
  crypto per symbol. `down` restores the columns empty; the vendor mapping is
  not restorable and would be re-derived by the sources anyway.
  """

  use Ecto.Migration

  def up do
    drop index(:assets, [:price_source, :source_id])

    alter table(:assets) do
      remove :price_source
      remove :source_id
      remove :exchange
      remove :wkn
    end

    create unique_index(:assets, [:isin, :mic],
             name: :assets_isin_mic_index,
             where: "isin IS NOT NULL AND mic IS NOT NULL"
           )

    create unique_index(:assets, [:symbol],
             name: :assets_crypto_symbol_index,
             where: "kind = 'crypto'"
           )

    # Crypto rows always carry a symbol and never security identity; the
    # richer security rules (new rows need isin+mic+ticker, migrated rows may
    # be unresolved) live in the changeset, which the DB cannot express.
    create constraint(:assets, :assets_crypto_shape,
             check:
               "kind <> 'crypto' OR (symbol IS NOT NULL AND ticker IS NULL AND mic IS NULL AND isin IS NULL)"
           )
  end

  def down do
    drop constraint(:assets, :assets_crypto_shape)
    drop index(:assets, [:symbol], name: :assets_crypto_symbol_index)
    drop index(:assets, [:isin, :mic], name: :assets_isin_mic_index)

    alter table(:assets) do
      add :price_source, :string
      add :source_id, :string
      add :exchange, :string
      add :wkn, :string
    end

    create unique_index(:assets, [:price_source, :source_id])
  end
end
