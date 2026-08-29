defmodule Folio.ImportExportTest do
  use Folio.DataCase, async: true

  import Folio.AssetsFixtures
  import Folio.PortfoliosFixtures

  alias Folio.Assets
  alias Folio.ImportExport
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates
  alias Folio.Portfolios

  describe "export_csv/1 and import_csv/2 round-trip" do
    test "reimporting an exported file recreates nothing and reports every row skipped" do
      portfolio = portfolio_fixture()
      asset = stock_asset_fixture()

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: asset.id,
        currency: "USD",
        executed_at: ~U[2025-01-01 00:00:00Z]
      })

      csv = portfolio.id |> ImportExport.export_csv() |> IO.iodata_to_binary()

      other = portfolio_fixture()
      assert {:ok, result} = ImportExport.import_csv(other.id, csv)
      assert result.inserted == 1
      assert result.skipped == 0
      assert result.invalid == []
      assert [imported] = Portfolios.list_transactions(other.id)
      assert Decimal.eq?(imported.quantity, "1")

      assert {:ok, repeat} = ImportExport.import_csv(other.id, csv)
      assert repeat.inserted == 0
      assert repeat.skipped == 1
      assert [^imported] = Portfolios.list_transactions(other.id)
    end

    test "creates the asset when it does not already exist" do
      portfolio = portfolio_fixture()
      asset = etf_asset_fixture()
      transaction = transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})

      csv = portfolio.id |> ImportExport.export_csv() |> IO.iodata_to_binary()

      # Simulate an instance that has never seen this asset: assets are
      # global, so the only way to test asset *creation* (rather than reuse)
      # is to remove the asset - and the transaction pinning it - first.
      Portfolios.delete_transaction(transaction)
      Repo.delete!(asset)

      other = portfolio_fixture()
      assert {:ok, %{inserted: 1}} = ImportExport.import_csv(other.id, csv)

      [imported] = Portfolios.list_transactions(other.id)
      recreated = Assets.get_asset!(imported.asset_id)
      assert recreated.isin == asset.isin
      assert recreated.mic == asset.mic
      refute recreated.id == asset.id
    end

    test "reuses an asset that already exists instead of creating a duplicate" do
      portfolio = portfolio_fixture()
      asset = stock_asset_fixture()
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id, currency: "USD"})

      csv = portfolio.id |> ImportExport.export_csv() |> IO.iodata_to_binary()

      other = portfolio_fixture()
      assets_before = length(Assets.list_assets())

      assert {:ok, %{inserted: 1}} = ImportExport.import_csv(other.id, csv)

      assert [imported] = Portfolios.list_transactions(other.id)
      assert imported.asset_id == asset.id
      assert length(Assets.list_assets()) == assets_before
    end

    test "batches the price/FX backfill once per distinct asset, not once per row" do
      portfolio = portfolio_fixture()
      asset = stock_asset_fixture()

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: asset.id,
        currency: "USD",
        executed_at: ~U[2025-03-01 00:00:00Z]
      })

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: asset.id,
        currency: "USD",
        executed_at: ~U[2025-01-01 00:00:00Z]
      })

      csv = portfolio.id |> ImportExport.export_csv() |> IO.iodata_to_binary()

      other = portfolio_fixture()
      assert {:ok, %{inserted: 2}} = ImportExport.import_csv(other.id, csv)

      [imported_asset_id] =
        other.id |> Portfolios.list_transactions() |> Enum.map(& &1.asset_id) |> Enum.uniq()

      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: imported_asset_id}

      # A single Oban insert per distinct asset: the earlier of the two dates
      # is used, so only one job (not two) is enqueued for this asset.
      jobs =
        all_enqueued(worker: BackfillAssetPrices)
        |> Enum.filter(&(&1.args["asset_id"] == imported_asset_id))

      assert length(jobs) == 1
      assert_enqueued worker: BackfillFxRates, args: %{currency: "USD", from: "2025-01-01"}
    end
  end

  describe "import_csv/2 with an invalid row" do
    test "reports the row without blocking the rest of the file" do
      portfolio = portfolio_fixture()
      asset = crypto_asset_fixture()
      transaction_fixture(%{portfolio_id: portfolio.id, asset_id: asset.id})

      csv = portfolio.id |> ImportExport.export_csv() |> IO.iodata_to_binary()
      [header_line, row_line] = String.split(csv, "\r\n", trim: true)

      quantity_index = header_line |> String.split(",") |> Enum.find_index(&(&1 == "quantity"))

      broken_fields =
        row_line |> String.split(",") |> List.replace_at(quantity_index, "not-a-number")

      broken_csv = Enum.join([header_line, Enum.join(broken_fields, ",")], "\r\n") <> "\r\n"

      other = portfolio_fixture()
      assert {:ok, result} = ImportExport.import_csv(other.id, broken_csv)
      assert result.inserted == 0
      assert [{1, changeset}] = result.invalid
      refute changeset.valid?
    end
  end

  describe "import_csv/2 with an unsupported file" do
    test "returns an error instead of raising" do
      portfolio = portfolio_fixture()
      assert {:error, _reason} = ImportExport.import_csv(portfolio.id, "not,a,folio,csv\n1,2,3,4")
    end
  end
end
