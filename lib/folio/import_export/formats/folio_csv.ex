defmodule Folio.ImportExport.Formats.FolioCsv do
  @moduledoc """
  Folio's own CSV format: close to the `transactions` table, with the
  asset's vendor-neutral identity (ISIN + MIC, or symbol for crypto)
  denormalized onto every row so a file is self-sufficient - importing it
  into an instance that has never seen the asset before still works.

  Implements `Folio.ImportExport.Format` for import, and additionally
  `encode/1` for export, since this is the only format Folio itself writes.
  """

  @behaviour Folio.ImportExport.Format

  alias Folio.Assets.Asset
  alias Folio.Portfolios.Transaction
  alias NimbleCSV.RFC4180, as: CSV

  @columns ~w(
    type executed_at quantity price_per_unit fee currency source external_id
    asset_kind asset_name asset_symbol asset_ticker asset_isin asset_mic asset_quote_currency
  )a
  @header Enum.map(@columns, &Atom.to_string/1)

  @doc "Encodes transaction/asset pairs as CSV iodata, header row first."
  @spec encode([{Transaction.t(), Asset.t()}]) :: iodata()
  def encode(pairs) do
    CSV.dump_to_iodata([@header | Enum.map(pairs, &encode_row/1)])
  end

  @impl true
  def parse(content) do
    case CSV.parse_string(content, skip_headers: false) do
      [] -> {:error, :empty_file}
      [header | rows] -> parse_rows(header, rows)
    end
  rescue
    NimbleCSV.ParseError -> {:error, :invalid_csv}
  end

  defp parse_rows(header, rows) do
    if Enum.sort(header) == Enum.sort(@header) do
      {:ok, Enum.map(rows, &to_row(header, &1))}
    else
      {:error, :unexpected_columns}
    end
  end

  defp to_row(header, values) do
    by_column = Map.new(Enum.zip(header, values))
    Map.new(@columns, &{&1, presence(Map.fetch!(by_column, Atom.to_string(&1)))})
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp encode_row({transaction, asset}) do
    [
      transaction.type,
      transaction.executed_at,
      transaction.quantity,
      transaction.price_per_unit,
      transaction.fee,
      transaction.currency,
      transaction.source || "folio",
      transaction.external_id || Integer.to_string(transaction.id),
      asset.kind,
      asset.name,
      asset.symbol,
      asset.ticker,
      asset.isin,
      asset.mic,
      asset.quote_currency
    ]
    |> Enum.map(&field_value/1)
  end

  defp field_value(nil), do: ""
  defp field_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp field_value(%Decimal{} = value), do: Decimal.to_string(value)
  defp field_value(value) when is_atom(value), do: Atom.to_string(value)
  defp field_value(value), do: value
end
