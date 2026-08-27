defmodule Folio.MarketDataTest do
  use Folio.DataCase, async: true

  import Folio.AssetsFixtures
  import Folio.MarketDataFixtures

  alias Folio.MarketData
  alias Folio.MarketData.Workers.BackfillAssetPrices

  describe "upserts" do
    test "daily price upserts are idempotent and replace the price" do
      asset = crypto_asset_fixture()

      :ok =
        MarketData.upsert_daily_prices(asset.id, [
          %{date: ~D[2025-01-01], price: Decimal.new("100")}
        ])

      :ok =
        MarketData.upsert_daily_prices(asset.id, [
          %{date: ~D[2025-01-01], price: Decimal.new("101")}
        ])

      assert [%{date: ~D[2025-01-01], price: price}] = MarketData.daily_prices(asset.id)
      assert Decimal.eq?(price, "101")
    end

    test "intraday upserts truncate to seconds and are idempotent" do
      asset = crypto_asset_fixture()
      at = ~U[2025-01-01 10:00:00.123456Z]

      :ok = MarketData.upsert_intraday_prices(asset.id, [%{at: at, price: Decimal.new("5")}])
      :ok = MarketData.upsert_intraday_prices(asset.id, [%{at: at, price: Decimal.new("6")}])

      assert [%{at: ~U[2025-01-01 10:00:00Z], price: price}] =
               MarketData.intraday_prices(asset.id)

      assert Decimal.eq?(price, "6")
    end

    test "fx upserts are idempotent per currency and date" do
      :ok = MarketData.upsert_fx_rates("USD", [%{date: ~D[2025-01-01], rate: Decimal.new("1.1")}])
      :ok = MarketData.upsert_fx_rates("USD", [%{date: ~D[2025-01-01], rate: Decimal.new("1.2")}])

      assert [%{rate: rate}] = MarketData.fx_rates("USD")
      assert Decimal.eq?(rate, "1.2")
    end
  end

  describe "queries" do
    test "series queries honor :from and report earliest dates" do
      asset = crypto_asset_fixture()
      seed_daily_prices(asset.id, ~D[2025-01-01], ~D[2025-01-10], "100", "1")

      assert MarketData.earliest_daily_price_date(asset.id) == ~D[2025-01-01]
      assert length(MarketData.daily_prices(asset.id, from: ~D[2025-01-08])) == 3

      seed_fx_rates("USD", ~D[2025-01-06], ~D[2025-01-10], "1.1", "0.01")
      assert MarketData.earliest_fx_rate_date("USD") == ~D[2025-01-06]
      assert MarketData.earliest_fx_rate_date("GBP") == nil
    end

    test "latest_price/1 prefers the newest of intraday tick and daily close" do
      asset = crypto_asset_fixture()
      assert MarketData.latest_price(asset.id) == nil

      seed_daily_prices(asset.id, ~D[2025-01-01], ~D[2025-01-02], "100", "1")
      assert %{price: price} = MarketData.latest_price(asset.id)
      assert Decimal.eq?(price, "101")

      seed_intraday_prices(asset.id, ~U[2025-01-02 10:00:00Z], ~U[2025-01-02 10:00:00Z], "150")
      assert %{at: ~U[2025-01-02 10:00:00Z], price: tick} = MarketData.latest_price(asset.id)
      assert Decimal.eq?(tick, "150")
    end
  end

  describe "ensure_history/3" do
    test "enqueues only when coverage is missing" do
      asset = crypto_asset_fixture()
      seed_daily_prices(asset.id, ~D[2025-01-01], ~D[2025-01-31], "100", "1")

      assert :ok = MarketData.ensure_history(asset.id, ~D[2025-01-15], "EUR")
      refute_enqueued worker: BackfillAssetPrices

      assert :ok = MarketData.ensure_history(asset.id, ~D[2024-06-01], "EUR")
      assert_enqueued worker: BackfillAssetPrices, args: %{asset_id: asset.id}
    end

    test "a repeated enqueue collapses without dropping the wider window" do
      asset = crypto_asset_fixture()

      assert :ok = MarketData.ensure_history(asset.id, ~D[2025-06-01], "EUR")
      assert :ok = MarketData.ensure_history(asset.id, ~D[2020-01-01], "EUR")

      # The window lives on the asset, not in the args, so one job serves both.
      assert [_only_one] = all_enqueued(worker: BackfillAssetPrices)
    end
  end

  describe "force_backfill/1" do
    test "enqueues even when a job for the asset is already pending" do
      asset = crypto_asset_fixture()

      assert :ok = MarketData.ensure_history(asset.id, ~D[2020-01-01], "EUR")
      assert {:ok, job} = MarketData.force_backfill(asset.id)

      refute job.conflict?
      assert job.args == %{asset_id: asset.id}
    end
  end

  describe "rollup and pruning" do
    test "rollup_day/1 writes each asset's last tick of the day as the close" do
      asset = crypto_asset_fixture()
      other = crypto_asset_fixture()

      :ok =
        MarketData.upsert_intraday_prices(asset.id, [
          %{at: ~U[2025-01-01 09:00:00Z], price: Decimal.new("100")},
          %{at: ~U[2025-01-01 21:00:00Z], price: Decimal.new("110")},
          %{at: ~U[2025-01-02 01:00:00Z], price: Decimal.new("999")}
        ])

      :ok =
        MarketData.upsert_intraday_prices(other.id, [
          %{at: ~U[2025-01-01 12:00:00Z], price: Decimal.new("7")}
        ])

      assert MarketData.rollup_day(~D[2025-01-01]) == 2

      assert [%{date: ~D[2025-01-01], price: close}] = MarketData.daily_prices(asset.id)
      assert Decimal.eq?(close, "110")
      assert [%{price: other_close}] = MarketData.daily_prices(other.id)
      assert Decimal.eq?(other_close, "7")
    end

    test "prune_intraday/1 deletes only ticks older than the cutoff" do
      asset = crypto_asset_fixture()

      :ok =
        MarketData.upsert_intraday_prices(asset.id, [
          %{at: ~U[2025-01-01 00:00:00Z], price: Decimal.new("1")},
          %{at: ~U[2025-01-09 00:00:00Z], price: Decimal.new("2")}
        ])

      assert MarketData.prune_intraday(~U[2025-01-08 00:00:00Z]) == 1
      assert [%{at: ~U[2025-01-09 00:00:00Z]}] = MarketData.intraday_prices(asset.id)
    end
  end

  describe "latest_prices/1" do
    test "one batch answer per asset, newest of tick vs close" do
      import Folio.AssetsFixtures

      tick_asset = crypto_asset_fixture()
      close_asset = stock_asset_fixture()
      empty_asset = etf_asset_fixture()

      :ok =
        MarketData.upsert_daily_prices(tick_asset.id, [
          %{date: ~D[2026-08-25], price: Decimal.new("100")}
        ])

      :ok =
        MarketData.upsert_intraday_prices(tick_asset.id, [
          %{at: ~U[2026-08-25 14:00:00Z], price: Decimal.new("101")}
        ])

      :ok =
        MarketData.upsert_daily_prices(close_asset.id, [
          %{date: ~D[2026-08-24], price: Decimal.new("50")}
        ])

      prices = MarketData.latest_prices([tick_asset.id, close_asset.id, empty_asset.id])

      assert %{at: ~U[2026-08-25 14:00:00Z], price: tick_price} = prices[tick_asset.id]
      assert Decimal.eq?(tick_price, "101")
      assert %{at: ~U[2026-08-24 00:00:00Z]} = prices[close_asset.id]
      refute Map.has_key?(prices, empty_asset.id)
    end
  end
end
