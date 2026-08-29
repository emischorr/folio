defmodule Folio.ImportExport do
  @moduledoc """
  Backing up and restoring transactions as CSV, and the seam for import file
  shapes other than our own. `Folio.ImportExport.Format` is the pluggable
  behaviour; `Folio.ImportExport.Formats.FolioCsv` is the only
  implementation today, both for export and for round-tripping our own file
  back in.
  """

  alias Folio.Assets
  alias Folio.ImportExport.Formats.FolioCsv
  alias Folio.Portfolios

  @doc "All of a portfolio's transactions as CSV, oldest first."
  @spec export_csv(pos_integer()) :: iodata()
  def export_csv(portfolio_id) do
    portfolio_id |> Portfolios.list_transactions() |> encode()
  end

  @doc "One asset's transactions in a portfolio, as CSV."
  @spec export_csv(pos_integer(), pos_integer()) :: iodata()
  def export_csv(portfolio_id, asset_id) do
    portfolio_id |> Portfolios.list_transactions(asset_id: asset_id) |> encode()
  end

  @doc """
  Imports transactions from file content via the given format (Folio's own
  CSV by default). Distinct assets are resolved or created once - never
  once per row - before any transaction is inserted, so a large file
  spanning a handful of distinct assets triggers a handful of asset
  lookups/backfills, not one per row. A row whose asset cannot be resolved
  is left without an `asset_id` and reported back as invalid, alongside any
  row that fails transaction validation, rather than aborting the import.
  """
  @spec import_csv(pos_integer(), binary(), module()) ::
          {:ok, Portfolios.import_result()} | {:error, term()}
  def import_csv(portfolio_id, content, format \\ FolioCsv) do
    with {:ok, rows} <- format.parse(content) do
      asset_ids_by_identity = resolve_assets(rows)
      attrs_list = Enum.map(rows, &transaction_attrs(&1, asset_ids_by_identity))
      {:ok, Portfolios.import_transactions(portfolio_id, attrs_list)}
    end
  end

  defp encode(transactions) do
    assets =
      transactions
      |> Enum.map(& &1.asset_id)
      |> Enum.uniq()
      |> Map.new(&{&1, Assets.get_asset!(&1)})

    transactions
    |> Enum.map(&{&1, Map.fetch!(assets, &1.asset_id)})
    |> FolioCsv.encode()
  end

  defp resolve_assets(rows) do
    rows
    |> Enum.uniq_by(&identity/1)
    |> Map.new(&{identity(&1), resolve_asset_id(identity(&1), &1)})
  end

  defp identity(row), do: Map.take(row, [:asset_kind, :asset_symbol, :asset_isin, :asset_mic])

  defp resolve_asset_id(identity, row) do
    case identity_lookup(identity) do
      :error -> nil
      {:ok, lookup} -> find_or_create_asset_id(lookup, row)
    end
  end

  defp find_or_create_asset_id(lookup, row) do
    case Assets.get_by_identity(lookup) do
      nil -> create_asset_id(row)
      asset -> asset.id
    end
  end

  defp create_asset_id(row) do
    case Assets.create_asset(asset_attrs(row)) do
      {:ok, asset} -> asset.id
      {:error, _changeset} -> nil
    end
  end

  defp identity_lookup(%{asset_kind: "crypto", asset_symbol: symbol}) when is_binary(symbol) do
    {:ok, %{kind: :crypto, symbol: symbol}}
  end

  defp identity_lookup(%{asset_isin: isin, asset_mic: mic})
       when is_binary(isin) and is_binary(mic) do
    {:ok, %{isin: isin, mic: mic}}
  end

  defp identity_lookup(_incomplete), do: :error

  defp asset_attrs(row) do
    %{
      kind: row.asset_kind,
      name: row.asset_name,
      symbol: row.asset_symbol,
      ticker: row.asset_ticker,
      isin: row.asset_isin,
      mic: row.asset_mic,
      quote_currency: row.asset_quote_currency
    }
  end

  defp transaction_attrs(row, asset_ids_by_identity) do
    row
    |> Map.take([
      :type,
      :executed_at,
      :quantity,
      :price_per_unit,
      :fee,
      :currency,
      :source,
      :external_id
    ])
    |> Map.put(:asset_id, Map.fetch!(asset_ids_by_identity, identity(row)))
  end
end
