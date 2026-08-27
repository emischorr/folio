defmodule Folio.MarketData.Workers.RefreshWorkersTest do
  use Folio.DataCase, async: true

  @moduletag :capture_log

  import Folio.ApiStubCase
  import Folio.AssetsFixtures

  alias Folio.MarketData
  alias Folio.MarketData.Workers.RefreshCryptoPrices
  alias Folio.MarketData.Workers.RefreshEquityPrices

  describe "RefreshCryptoPrices" do
    test "writes one intraday tick per crypto asset from a single batched call" do
      bitcoin = crypto_asset_fixture(%{source_id: "bitcoin"})
      ethereum = crypto_asset_fixture(%{source_id: "ethereum", symbol: "ETH", name: "Ethereum"})

      Req.Test.stub(Folio.Clients, fn conn ->
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
      crypto_asset_fixture(%{source_id: "bitcoin"})
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 429) end)

      assert {:cancel, :rate_limited} =
               perform_job(RefreshCryptoPrices, %{}, max_attempts: 6)

      assert {:snooze, 120} = perform_job(RefreshCryptoPrices, %{})
    end
  end

  describe "RefreshEquityPrices" do
    test "trading_hours?/1 opens weekdays 06:00-22:00 UTC only" do
      assert RefreshEquityPrices.trading_hours?(~U[2026-08-24 12:00:00Z])
      assert RefreshEquityPrices.trading_hours?(~U[2026-08-24 06:00:00Z])
      refute RefreshEquityPrices.trading_hours?(~U[2026-08-24 05:59:59Z])
      refute RefreshEquityPrices.trading_hours?(~U[2026-08-24 22:00:00Z])
      refute RefreshEquityPrices.trading_hours?(~U[2026-08-22 12:00:00Z])
      refute RefreshEquityPrices.trading_hours?(~U[2026-08-23 12:00:00Z])
    end

    test "writes a tick per equity asset during trading hours" do
      asset = stock_asset_fixture(%{source_id: "NVDA"})

      Req.Test.stub(Folio.Clients, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(RefreshEquityPrices, %{now: "2026-08-24T12:00:00Z"})

      assert [%{at: ~U[2026-08-24 12:00:00Z], price: price}] =
               MarketData.intraday_prices(asset.id)

      assert Decimal.eq?(price, "213.44")
    end

    test "does nothing outside trading hours" do
      stock_asset_fixture(%{source_id: "NVDA"})

      assert :ok = perform_job(RefreshEquityPrices, %{now: "2026-08-23T12:00:00Z"})
      assert Folio.Repo.aggregate(Folio.MarketData.IntradayPrice, :count) == 0
    end

    test "one failing symbol does not fail the others" do
      good = stock_asset_fixture(%{source_id: "NVDA"})
      stock_asset_fixture(%{source_id: "BROKEN", symbol: "BRK"})

      Req.Test.stub(Folio.Clients, fn conn ->
        case conn.request_path do
          "/v8/finance/chart/NVDA" -> json_fixture(conn, "yahoo_chart_nvda.json")
          "/v8/finance/chart/BROKEN" -> json_body(conn, "{}", 500)
        end
      end)

      assert :ok = perform_job(RefreshEquityPrices, %{now: "2026-08-24T12:00:00Z"})
      assert [_tick] = MarketData.intraday_prices(good.id)
    end

    test "errors when every symbol fails" do
      stock_asset_fixture(%{source_id: "BROKEN"})
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 500) end)

      assert {:error, :all_sources_failed} =
               perform_job(RefreshEquityPrices, %{now: "2026-08-24T12:00:00Z"})
    end
  end
end
