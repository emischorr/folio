defmodule Folio.MarketData.Workers.NightlyRollupTest do
  use Folio.DataCase, async: true

  import Folio.ApiStubCase
  import Folio.AssetsFixtures
  import Folio.MarketDataFixtures

  alias Folio.MarketData
  alias Folio.MarketData.Workers.NightlyRollup

  test "rolls up yesterday's closes, prunes past retention, and refreshes FX" do
    crypto = crypto_asset_fixture()
    stock = stock_asset_fixture(%{source_id: "NVDA"})

    # Yesterday's ticks (relative to the injected "today" 2026-08-25).
    :ok =
      MarketData.upsert_intraday_prices(crypto.id, [
        %{at: ~U[2026-08-24 10:00:00Z], price: Decimal.new("100")},
        %{at: ~U[2026-08-24 23:45:00Z], price: Decimal.new("105")}
      ])

    # A tick past the 8-day retention window.
    seed_intraday_prices(crypto.id, ~U[2026-08-10 12:00:00Z], ~U[2026-08-10 12:00:00Z], "90")

    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/v1/latest"
      assert conn.params["symbols"] == "USD"
      json_fixture(conn, "frankfurter_latest.json")
    end)

    assert :ok = perform_job(NightlyRollup, %{today: "2026-08-25"})

    assert [%{date: ~D[2026-08-24], price: close}] = MarketData.daily_prices(crypto.id)
    assert Decimal.eq?(close, "105")

    refute Enum.any?(
             MarketData.intraday_prices(crypto.id),
             &(DateTime.to_date(&1.at) == ~D[2026-08-10])
           )

    assert [%{date: ~D[2026-08-25], rate: rate}] = MarketData.fx_rates("USD")
    assert Decimal.eq?(rate, "1.1662")

    assert MarketData.daily_prices(stock.id) == []
  end

  test "skips the FX call when only EUR is in use" do
    crypto = crypto_asset_fixture()
    seed_intraday_prices(crypto.id, ~U[2026-08-24 12:00:00Z], ~U[2026-08-24 12:00:00Z], "50")

    assert :ok = perform_job(NightlyRollup, %{today: "2026-08-25"})
    assert [%{date: ~D[2026-08-24]}] = MarketData.daily_prices(crypto.id)
  end
end
