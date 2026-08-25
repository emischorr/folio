defmodule Folio.Clients.CoinGeckoTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.Clients.CoinGecko

  test "search/1 parses coins into search hits" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.host == "api.coingecko.com"
      assert conn.request_path == "/api/v3/search"
      json_fixture(conn, "coingecko_search.json")
    end)

    assert {:ok, [first | _rest] = hits} = CoinGecko.search("bitcoin")
    assert length(hits) == 3
    assert first == %{source_id: "bitcoin", symbol: "BTC", name: "Bitcoin"}
  end

  test "daily_history/3 returns Decimal prices, one per date, last partial tick winning" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/api/v3/coins/bitcoin/market_chart"
      assert conn.params["vs_currency"] == "eur"
      json_fixture(conn, "coingecko_market_chart.json")
    end)

    assert {:ok, entries} = CoinGecko.daily_history("bitcoin", "EUR", 5)
    # The fixture has 6 rows; the last is a same-day partial that replaces the close.
    assert length(entries) == 5
    assert entries == Enum.uniq_by(entries, & &1.date)
    assert Enum.all?(entries, &match?(%Decimal{}, &1.price))
    assert Decimal.eq?(List.last(entries).price, "67640.4942467496")
  end

  test "current_prices/2 coerces integer JSON prices to Decimal" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/api/v3/simple/price"
      json_fixture(conn, "coingecko_simple_price.json")
    end)

    assert {:ok, prices} = CoinGecko.current_prices(["bitcoin", "ethereum"], "EUR")
    assert Decimal.eq?(prices["bitcoin"], "67611")
    assert Decimal.eq?(prices["ethereum"], "2114.63")
  end

  test "HTTP 429 maps to :rate_limited" do
    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 429) end)

    assert {:error, :rate_limited} = CoinGecko.search("bitcoin")
  end
end
