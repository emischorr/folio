defmodule Folio.MarketData.Workers.RefreshWorkersTest do
  use Folio.DataCase, async: true

  @moduletag :capture_log

  import Folio.ApiStubCase
  import Folio.AssetsFixtures

  alias Folio.MarketData
  alias Folio.MarketData.Workers.RefreshCryptoPrices
  alias Folio.MarketData.Workers.RefreshSecurityPrices

  # Monday, 15:00 UTC: Xetra (17:00 CEST) and NYSE/Nasdaq (11:00 New York)
  # are both in session.
  @open_now "2026-08-24T15:00:00Z"

  describe "RefreshCryptoPrices" do
    test "writes one intraday tick per crypto asset from a single batched call" do
      bitcoin = crypto_asset_fixture(%{symbol: "BTC"})
      ethereum = crypto_asset_fixture(%{symbol: "ETH", name: "Ethereum"})

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/api/v3/simple/price"
        assert conn.params["ids"] =~ "bitcoin"
        json_fixture(conn, "coingecko_simple_price.json")
      end)

      assert :ok = perform_job(RefreshCryptoPrices, %{})

      assert [%{price: bitcoin_price}] = MarketData.intraday_prices(bitcoin.id)
      assert Decimal.eq?(bitcoin_price, "67611")
      assert [%{price: ethereum_price}] = MarketData.intraday_prices(ethereum.id)
      assert Decimal.eq?(ethereum_price, "2114.63")
    end

    test "is a no-op without crypto assets" do
      assert :ok = perform_job(RefreshCryptoPrices, %{})
    end

    test "rate limiting snoozes, then cancels at the limit" do
      crypto_asset_fixture(%{symbol: "BTC"})
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

      assert {:cancel, :rate_limited} =
               perform_job(RefreshCryptoPrices, %{}, max_attempts: 6)

      assert {:snooze, 120} = perform_job(RefreshCryptoPrices, %{})
    end
  end

  describe "RefreshSecurityPrices" do
    test "writes a tick per security while its venue is open" do
      asset = stock_asset_fixture()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(RefreshSecurityPrices, %{now: @open_now})

      # The tick carries the provider's quote time, not the poll time.
      assert [%{at: ~U[2026-08-25 14:12:22Z], price: price}] =
               MarketData.intraday_prices(asset.id)

      assert Decimal.eq?(price, "213.44")
    end

    test "EUR listings on German venues are quoted by Tradegate first" do
      asset = etf_asset_fixture()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.host == "www.tradegatebsx.com"
        assert conn.params["isin"] == asset.isin
        json_fixture(conn, "tradegate_refresh.json")
      end)

      assert :ok = perform_job(RefreshSecurityPrices, %{now: @open_now})
      assert [%{price: price}] = MarketData.intraday_prices(asset.id)
      assert Decimal.eq?(price, "127.185")
    end

    test "skips listings whose venue is closed" do
      stock_asset_fixture()

      Req.Test.stub(Folio.MarketData.Sources, fn _conn ->
        raise "a closed venue must not be polled"
      end)

      # Sunday midday: every venue closed.
      assert :ok = perform_job(RefreshSecurityPrices, %{now: "2026-08-23T12:00:00Z"})
      assert Folio.Repo.aggregate(Folio.MarketData.IntradayPrice, :count) == 0
    end

    test "skips unresolved securities entirely" do
      stock_asset_fixture(%{mic: nil, isin: nil})

      Req.Test.stub(Folio.MarketData.Sources, fn _conn ->
        raise "an unresolved asset must not be polled"
      end)

      assert :ok = perform_job(RefreshSecurityPrices, %{now: @open_now})
    end

    test "one failing listing does not fail the others" do
      good = stock_asset_fixture()
      stock_asset_fixture(%{ticker: "BROKEN"})

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        case conn.request_path do
          "/v8/finance/chart/NVDA" -> json_fixture(conn, "yahoo_chart_nvda.json")
          "/v8/finance/chart/BROKEN" -> json_body(conn, "{}", 500)
        end
      end)

      assert :ok = perform_job(RefreshSecurityPrices, %{now: @open_now})
      assert [_tick] = MarketData.intraday_prices(good.id)
    end

    test "errors when every listing fails" do
      stock_asset_fixture(%{ticker: "BROKEN"})
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 500) end)

      assert {:error, :all_sources_failed} =
               perform_job(RefreshSecurityPrices, %{now: @open_now})
    end
  end
end
