defmodule Folio.AssetsTest do
  use Folio.DataCase, async: true

  import Folio.AssetsFixtures

  alias Folio.Assets
  alias Folio.Assets.Asset
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates

  describe "create_asset/1" do
    test "stores vendor-neutral identity and enqueues an initial backfill" do
      attrs = %{
        ticker: "NVDA",
        name: "NVIDIA Corporation",
        kind: :stock,
        mic: "XNAS",
        isin: "US67066G1040",
        quote_currency: "USD"
      }

      assert {:ok, asset} = Assets.create_asset(attrs)
      assert asset.ticker == "NVDA"
      assert asset.mic == "XNAS"
      assert asset.symbol == nil

      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id}
      assert_enqueued worker: BackfillFxRates, args: %{currency: "USD"}
    end

    test "a security needs its full identity" do
      assert {:error, changeset} =
               Assets.create_asset(%{
                 name: "iShares S&P 500 IT",
                 kind: :etf,
                 quote_currency: "EUR"
               })

      assert %{ticker: [_], mic: [_], isin: [_]} = errors_on(changeset)
    end

    test "an unknown MIC is rejected" do
      assert {:error, changeset} =
               Assets.create_asset(%{
                 ticker: "QDVE",
                 name: "iShares S&P 500 IT",
                 kind: :etf,
                 mic: "XXXX",
                 isin: "IE00B3WJKG14",
                 quote_currency: "EUR"
               })

      assert %{mic: [_message]} = errors_on(changeset)
    end

    test "the same ISIN on two venues is two assets; on the same venue it is a duplicate" do
      isin = unique_isin()

      assert {:ok, _xetra} =
               Assets.create_asset(%{
                 ticker: "QDVE",
                 name: "iShares S&P 500 IT",
                 kind: :etf,
                 mic: "XETR",
                 isin: isin,
                 quote_currency: "EUR"
               })

      assert {:ok, _london} =
               Assets.create_asset(%{
                 ticker: "IUIT",
                 name: "iShares S&P 500 IT",
                 kind: :etf,
                 mic: "XLON",
                 isin: isin,
                 quote_currency: "GBP"
               })

      assert {:error, changeset} =
               Assets.create_asset(%{
                 ticker: "QDVE",
                 name: "iShares S&P 500 IT again",
                 kind: :etf,
                 mic: "XETR",
                 isin: isin,
                 quote_currency: "EUR"
               })

      assert %{isin: [_message]} = errors_on(changeset)
    end

    test "crypto needs only a symbol and rejects a duplicate" do
      assert {:ok, asset} =
               Assets.create_asset(%{
                 symbol: "sol",
                 name: "Solana",
                 kind: :crypto,
                 quote_currency: "EUR"
               })

      assert asset.symbol == "SOL"

      assert {:error, changeset} =
               Assets.create_asset(%{
                 symbol: "SOL",
                 name: "Solana again",
                 kind: :crypto,
                 quote_currency: "EUR"
               })

      assert %{symbol: [_message]} = errors_on(changeset)
    end
  end

  describe "search_local/1" do
    test "matches ticker, symbol and name case-insensitively" do
      crypto = crypto_asset_fixture(%{symbol: "BTC"})
      stock = stock_asset_fixture()

      assert [found] = Assets.search_local("bitc")
      assert found.id == crypto.id
      assert [_found] = Assets.search_local("btc")
      assert [found_stock] = Assets.search_local("nvd")
      assert found_stock.id == stock.id
    end

    test "escapes LIKE wildcards" do
      crypto_asset_fixture()
      assert Assets.search_local("%") == []
    end

    test "matches an exact ISIN, however it is typed" do
      asset = etf_asset_fixture(%{isin: "IE00B44Z5B48"})

      assert [found] = Assets.search_local("IE00B44Z5B48")
      assert found.id == asset.id
      assert [_found] = Assets.search_local("ie00 b44z-5b48")
    end
  end

  describe "resolve_identity/2" do
    test "an invalid ISIN is rejected" do
      asset = stock_asset_fixture(%{isin: nil})

      assert {:error, changeset} = Assets.resolve_identity(asset.id, %{isin: "IE00B44Z5B49"})
      assert %{isin: ["is not a valid ISIN"]} = errors_on(changeset)
    end

    test "fills blanks but never overwrites a stored value" do
      asset = etf_asset_fixture(%{isin: nil, mic: nil})

      assert {:ok, updated} =
               Assets.resolve_identity(asset.id, %{
                 isin: "IE00B44Z5B48",
                 mic: "XFRA",
                 ticker: "OTHER"
               })

      assert updated.isin == "IE00B44Z5B48"
      assert updated.mic == "XFRA"
      # ticker was already stored and stays untouched
      assert updated.ticker == asset.ticker
      refute Asset.unresolved?(updated)
    end

    test "enqueues the backfill once the asset becomes resolved" do
      asset = etf_asset_fixture(%{isin: nil})

      assert {:ok, _updated} = Assets.resolve_identity(asset.id, %{isin: "IE00B44Z5B48"})
      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id}
    end

    test "is a no-op when there is nothing to fill" do
      asset = etf_asset_fixture()

      assert Assets.resolve_identity(asset.id, %{isin: "IE00B44Z5B48"}) == :noop
      assert Assets.resolve_identity(asset.id, %{isin: nil, mic: nil, ticker: nil}) == :noop
    end
  end

  describe "list_refreshable/1" do
    test "crypto by kind; securities minus the unresolved" do
      crypto = crypto_asset_fixture()
      resolved = stock_asset_fixture()
      unresolved = etf_asset_fixture(%{isin: nil})

      assert [%{id: crypto_id}] = Assets.list_refreshable(:crypto)
      assert crypto_id == crypto.id

      security_ids = Enum.map(Assets.list_refreshable(:security), & &1.id)
      assert resolved.id in security_ids
      refute unresolved.id in security_ids
    end
  end

  describe "unresolved?/1 and display_code/1" do
    test "derived unresolved state and display fallback" do
      refute Asset.unresolved?(crypto_asset_fixture())
      refute Asset.unresolved?(stock_asset_fixture())
      assert Asset.unresolved?(etf_asset_fixture(%{mic: nil}))

      legacy = stock_asset_fixture(%{ticker: nil, symbol: "NVDA-LEGACY", isin: nil, mic: nil})
      assert Asset.unresolved?(legacy)
      assert Asset.display_code(legacy) == "NVDA-LEGACY"
      assert Asset.display_code(stock_asset_fixture()) == "NVDA"
    end
  end

  describe "listing/1" do
    test "maps an asset to the market-data listing shape" do
      asset = etf_asset_fixture()

      assert Assets.listing(asset) == %{
               asset_id: asset.id,
               kind: :etf,
               symbol: nil,
               ticker: "EUNL",
               isin: asset.isin,
               mic: "XETR",
               quote_currency: "EUR"
             }
    end
  end

  describe "get_by_identity/1" do
    test "finds a crypto asset by symbol, case-insensitively" do
      bitcoin = crypto_asset_fixture(%{symbol: "BTC"})

      assert Assets.get_by_identity(%{kind: :crypto, symbol: "btc"}).id == bitcoin.id
      assert Assets.get_by_identity(%{kind: :crypto, symbol: "ETH"}) == nil
    end

    test "finds a security by ISIN + MIC" do
      asset = stock_asset_fixture()

      assert Assets.get_by_identity(%{isin: asset.isin, mic: asset.mic}).id == asset.id
      assert Assets.get_by_identity(%{isin: asset.isin, mic: "XETR"}) == nil
    end
  end
end
