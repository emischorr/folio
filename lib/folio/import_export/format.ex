defmodule Folio.ImportExport.Format do
  @moduledoc """
  Behaviour for turning an import file's bytes into the canonical row shape
  transactions are built from. A new file shape (a broker's own export,
  say) is a new module implementing `parse/1` that maps its own columns
  onto this same field set - `Folio.ImportExport` and `Folio.Portfolios`
  never need to change.

  Fields are left as the raw text a file contains rather than pre-parsed
  into `Decimal`/`DateTime`/enum values: `Ecto.Changeset.cast/3` on
  `Transaction` and `Asset` is already the single, tested place decimals,
  dates and enums are parsed and validated, so a format only has to get the
  right text under the right field name and let that validation run once,
  downstream.
  """

  @type row :: %{
          type: String.t(),
          executed_at: String.t(),
          quantity: String.t(),
          price_per_unit: String.t(),
          fee: String.t() | nil,
          currency: String.t() | nil,
          source: String.t() | nil,
          external_id: String.t() | nil,
          asset_kind: String.t(),
          asset_name: String.t(),
          asset_symbol: String.t() | nil,
          asset_ticker: String.t() | nil,
          asset_isin: String.t() | nil,
          asset_mic: String.t() | nil,
          asset_quote_currency: String.t()
        }

  @doc "Parses file content into rows; an empty list is a valid answer."
  @callback parse(binary()) :: {:ok, [row()]} | {:error, term()}
end
