defmodule Folio.MarketData.Workers.BackfillWorkersTest do
  use Folio.DataCase, async: true

  import Folio.ApiStubCase
  import Folio.AssetsFixtures
  import Folio.PortfoliosFixtures

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

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})
      assert length(MarketData.daily_prices(asset.id)) == 5
    end

    test "stores daily closes for an equity asset via the equity client" do
      asset = stock_asset_fixture(%{source_id: "NVDA"})

      Req.Test.stub(Folio.Clients, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})
      assert length(MarketData.daily_prices(asset.id)) == 5
    end

    test "a deleted asset completes without work" do
      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: -1})
    end

    test "the window reaches back to the asset's earliest transaction" do
      asset = stock_asset_fixture(%{source_id: "NVDA"})
      portfolio = portfolio_fixture()

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: asset.id,
        executed_at: ~U[2019-03-04 10:00:00Z]
      })

      test_pid = self()

      Req.Test.stub(Folio.Clients, fn conn ->
        send(test_pid, {:period1, conn.params["period1"]})
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})

      assert_received {:period1, period1}
      requested = period1 |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_date()
      assert requested == ~D[2019-03-04]
    end

    test "without transactions the window is the default initial history" do
      asset = stock_asset_fixture(%{source_id: "NVDA"})
      test_pid = self()

      Req.Test.stub(Folio.Clients, fn conn ->
        send(test_pid, {:period1, conn.params["period1"]})
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})

      assert_received {:period1, period1}
      requested = period1 |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_date()
      assert requested == Date.add(Date.utc_today(), -Folio.Assets.initial_history_days())
    end

    test "rate limiting snoozes with a doubling backoff, then cancels" do
      asset = crypto_asset_fixture(%{source_id: "bitcoin"})
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 429) end)

      # Oban raises max_attempts on every snooze, so the gap above the worker's
      # declared 5 is the number of snoozes already spent.
      assert {:snooze, 120} = backfill_with_max_attempts(asset.id, 5)
      assert {:snooze, 240} = backfill_with_max_attempts(asset.id, 6)
      assert {:snooze, 480} = backfill_with_max_attempts(asset.id, 7)
      assert {:cancel, :rate_limited} = backfill_with_max_attempts(asset.id, 10)
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

    test "rate limiting cancels once the snooze limit is reached" do
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 429) end)

      assert {:snooze, 120} =
               perform_job(BackfillFxRates, %{currency: "USD", from: "2026-08-17"},
                 max_attempts: 5
               )

      assert {:cancel, :rate_limited} =
               perform_job(BackfillFxRates, %{currency: "USD", from: "2026-08-17"},
                 max_attempts: 10
               )
    end
  end

  defp backfill_with_max_attempts(asset_id, max_attempts) do
    perform_job(BackfillAssetPrices, %{asset_id: asset_id}, max_attempts: max_attempts)
  end
end
