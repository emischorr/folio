defmodule Folio.MarketData.Workers.BackfillWorkersTest do
  use Folio.DataCase, async: true

  @moduletag :capture_log

  import Folio.ApiStubCase
  import Folio.AssetsFixtures
  import Folio.PortfoliosFixtures

  alias Folio.MarketData
  alias Folio.MarketData.Workers.BackfillAssetPrices
  alias Folio.MarketData.Workers.BackfillFxRates

  describe "BackfillAssetPrices" do
    test "stores daily closes for a crypto asset through the history chain" do
      asset = crypto_asset_fixture(%{symbol: "BTC"})

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/api/v3/coins/bitcoin/market_chart"
        json_fixture(conn, "coingecko_market_chart.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})
      assert length(MarketData.daily_prices(asset.id)) == 5
    end

    test "stores daily closes for a security through the history chain" do
      asset = stock_asset_fixture()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})
      assert length(MarketData.daily_prices(asset.id)) == 5
    end

    test "a deleted asset completes without work" do
      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: -1})
    end

    test "an unresolved security is skipped, not retried" do
      asset = stock_asset_fixture(%{mic: nil, isin: nil})

      Req.Test.stub(Folio.MarketData.Sources, fn _conn ->
        raise "no source supports an unresolved asset - nothing may be called"
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})
      assert MarketData.daily_prices(asset.id) == []
    end

    test "a deep window fetches the newest chunk and enqueues the rest at low priority" do
      asset = stock_asset_fixture()
      portfolio = portfolio_fixture()

      transaction_fixture(%{
        portfolio_id: portfolio.id,
        asset_id: asset.id,
        executed_at: ~U[2025-03-04 10:00:00Z]
      })

      test_pid = self()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        send(test_pid, {:period1, conn.params["period1"]})
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})

      # The root job itself fetched only the newest 366-day chunk...
      assert_received {:period1, period1}
      requested = period1 |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_date()
      assert requested == Date.add(Date.utc_today(), -365)

      # ...and enqueued the remainder, reaching back to the earliest transaction.
      assert [chunk] = all_enqueued(worker: BackfillAssetPrices)
      assert chunk.args["asset_id"] == asset.id
      assert chunk.args["from"] == "2025-03-04"
      assert chunk.args["to"] == Date.to_iso8601(Date.add(requested, -1))
      assert chunk.priority == 3
    end

    test "a chunk job fetches exactly its window" do
      asset = stock_asset_fixture()
      test_pid = self()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        send(test_pid, {:window, conn.params["period1"], conn.params["period2"]})
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok =
               perform_job(BackfillAssetPrices, %{
                 asset_id: asset.id,
                 from: "2025-03-04",
                 to: "2025-06-30"
               })

      assert_received {:window, period1, period2}
      assert String.to_integer(period1) == DateTime.to_unix(~U[2025-03-04 00:00:00Z])
      assert String.to_integer(period2) == DateTime.to_unix(~U[2025-07-01 00:00:00Z])
    end

    test "without transactions the window is the default initial history" do
      asset = stock_asset_fixture()
      test_pid = self()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        send(test_pid, {:period1, conn.params["period1"]})
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert :ok = perform_job(BackfillAssetPrices, %{asset_id: asset.id})

      assert_received {:period1, period1}
      requested = period1 |> String.to_integer() |> DateTime.from_unix!() |> DateTime.to_date()
      assert requested == Date.add(Date.utc_today(), -Folio.Assets.initial_history_days())
      assert all_enqueued(worker: BackfillAssetPrices) == []
    end

    test "rate limiting snoozes with a doubling backoff, then cancels" do
      asset = crypto_asset_fixture(%{symbol: "BTC"})
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

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
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path =~ ~r"^/v1/2026-08-17\.\."
        json_fixture(conn, "frankfurter_series.json")
      end)

      assert :ok = perform_job(BackfillFxRates, %{currency: "USD", from: "2026-08-17"})
      assert length(MarketData.fx_rates("USD")) == 5
      assert MarketData.earliest_fx_rate_date("USD") == ~D[2026-08-17]
    end

    test "failures become retryable errors" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 500) end)

      assert {:error, :failed} =
               perform_job(BackfillFxRates, %{currency: "USD", from: "2026-08-17"})
    end

    test "rate limiting cancels once the snooze limit is reached" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

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
