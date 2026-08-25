defmodule Folio.AssetsTest do
  use Folio.DataCase, async: true

  import Folio.AssetsFixtures

  alias Folio.Assets
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates

  describe "create_asset/1" do
    test "stores the source mapping and enqueues an initial backfill" do
      attrs = %{
        symbol: "NVDA",
        name: "NVIDIA Corporation",
        kind: :stock,
        exchange: "NasdaqGS",
        quote_currency: "USD",
        price_source: :yahoo,
        source_id: "NVDA"
      }

      assert {:ok, asset} = Assets.create_asset(attrs)
      assert asset.price_source == :yahoo

      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id}
      assert_enqueued worker: BackfillFxRates, args: %{currency: "USD"}
    end

    test "rejects a duplicate source mapping" do
      existing = crypto_asset_fixture()

      assert {:error, changeset} =
               Assets.create_asset(%{
                 symbol: "BTC",
                 name: "Bitcoin again",
                 kind: :crypto,
                 quote_currency: "EUR",
                 price_source: :coingecko,
                 source_id: existing.source_id
               })

      assert %{price_source: [_message]} = errors_on(changeset)
    end
  end

  describe "create_manual_asset/1" do
    test "derives the equity source mapping from the ticker" do
      attrs = %{
        symbol: "SAP.DE",
        name: "SAP SE",
        kind: :stock,
        exchange: "XETRA",
        quote_currency: "EUR"
      }

      assert {:ok, asset} = Assets.create_manual_asset(attrs)
      assert asset.price_source == :yahoo
      assert asset.source_id == "SAP.DE"
    end

    test "crypto requires an explicit source id" do
      assert {:error, changeset} =
               Assets.create_manual_asset(%{
                 symbol: "ETH",
                 name: "Ethereum",
                 kind: :crypto,
                 quote_currency: "EUR"
               })

      assert %{source_id: [_message]} = errors_on(changeset)

      assert {:ok, asset} =
               Assets.create_manual_asset(%{
                 symbol: "ETH",
                 name: "Ethereum",
                 kind: :crypto,
                 quote_currency: "EUR",
                 source_id: "ethereum"
               })

      assert asset.price_source == :coingecko
    end
  end

  describe "search_local/1" do
    test "matches symbol and name case-insensitively" do
      asset = crypto_asset_fixture()
      stock_asset_fixture()

      assert [found] = Assets.search_local("bitc")
      assert found.id == asset.id
      assert [_found] = Assets.search_local("btc")
    end

    test "escapes LIKE wildcards" do
      crypto_asset_fixture()
      assert Assets.search_local("%") == []
    end
  end
end
