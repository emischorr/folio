defmodule Folio.MarketData.Workers.BackfillWorkersTest do
  use Folio.DataCase, async: true

  import Folio.ApiStubCase
  import Folio.AssetsFixtures

  alias Folio.MarketData
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates

  describe "BackfillAssetPrices" do
    test "stores daily closes for a crypto asset via the crypto client" do
      asset = crypto_asset_fixture(%{source_id: "bitcoin"})

      Req.Test.stub(Folio.Clients, fn conn ->
        assert conn.request_path == "/api/v3/coins/bitcoin/market_chart"
        json_fixture(conn, "coingecko_market_chart.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id, from: "2026-08-18"})
      assert length(MarketData.daily_prices(asset.id)) == 5
    end

    test "stores daily closes for an equity asset via the equity client" do
      asset = stock_asset_fixture(%{source_id: "NVDA"})

      Req.Test.stub(Folio.Clients, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id, from: "2026-08-14"})
      assert length(MarketData.daily_prices(asset.id)) == 5
    end

    test "a deleted asset completes without work" do
      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: -1, from: "2026-08-14"})
    end

    test "rate limiting snoozes the job" do
      asset = crypto_asset_fixture(%{source_id: "bitcoin"})
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 429) end)

      assert {:snooze, 120} =
               perform_job(BackfillAssetPrices, %{asset_id: asset.id, from: "2026-08-18"})
    end
  end

  describe "BackfillFxRates" do
    test "stores the historical EUR-pivot rates" do
      Req.Test.stub(Folio.Clients, fn conn ->
        assert conn.request_path =~ ~r"^/v1/2026-08-17\.\."
        json_fixture(conn, "frankfurter_series.json")
      end)

      assert :ok = perform_job(BackfillFxRates, %{currency: "USD", from: "2026-08-17"})
      assert length(MarketData.fx_rates("USD")) == 5
      assert MarketData.earliest_fx_rate_date("USD") == ~D[2026-08-17]
    end

    test "failures become retryable errors" do
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 500) end)

      assert {:error, {:http_status, 500}} =
               perform_job(BackfillFxRates, %{currency: "USD", from: "2026-08-17"})
    end
  end
end
