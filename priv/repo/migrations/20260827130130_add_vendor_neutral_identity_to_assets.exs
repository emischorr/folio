defmodule Folio.Repo.Migrations.AddVendorNeutralIdentityToAssets do
  @moduledoc """
  First half of the vendor-neutral identity refactor: adds `mic` and `ticker`
  and derives them from the vendor fields (`price_source`/`source_id`/
  `exchange`), which a follow-up migration drops once the code no longer
  reads them. Underivable securities keep NULLs and surface as unresolved in
  the UI. `down` restores the columns but not the data - the derivation is
  one-way.
  """

  use Ecto.Migration

  alias Folio.Release.AssetIdentityMigration

  def up do
    alter table(:assets) do
      add :mic, :string
      add :ticker, :string
    end

    execute "ALTER TABLE assets ALTER COLUMN symbol DROP NOT NULL"

    flush()

    derive_identity()
    demote_duplicate_listings()
  end

  def down do
    execute "UPDATE assets SET symbol = COALESCE(symbol, ticker)"
    execute "ALTER TABLE assets ALTER COLUMN symbol SET NOT NULL"

    alter table(:assets) do
      remove :mic
      remove :ticker
    end
  end

  defp derive_identity do
    %{rows: rows} =
      repo().query!("SELECT id, kind, price_source, source_id, exchange FROM assets", [])

    for [id, kind, price_source, source_id, exchange] <- rows do
      row = %{kind: kind, price_source: price_source, source_id: source_id, exchange: exchange}

      case AssetIdentityMigration.derive(row) do
        :crypto ->
          :ok

        %{ticker: nil, mic: nil} ->
          :ok

        %{ticker: ticker, mic: mic} ->
          # Securities carry their code in `ticker` from here on; `symbol`
          # stays only as a display fallback where no ticker was derivable.
          repo().query!(
            "UPDATE assets SET ticker = $1, mic = $2, symbol = NULL WHERE id = $3",
            [ticker, mic, id]
          )
      end
    end
  end

  # Two legacy rows can derive to the same listing; the follow-up migration
  # adds a unique index on (isin, mic), so demote all but the first to
  # unresolved (repairable in the UI) instead of failing there.
  defp demote_duplicate_listings do
    repo().query!("""
    UPDATE assets SET mic = NULL WHERE id IN (
      SELECT id FROM (
        SELECT id, row_number() OVER (PARTITION BY isin, mic ORDER BY id) AS occurrence
        FROM assets
        WHERE isin IS NOT NULL AND mic IS NOT NULL
      ) ranked
      WHERE occurrence > 1
    )
    """)
  end
end
