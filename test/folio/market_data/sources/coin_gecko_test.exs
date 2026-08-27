defmodule Folio.MarketData.Sources.CoinGeckoTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.MarketData.Listing
  alias Folio.MarketData.Sources.CoinGecko

  @btc Listing.new(%{asset_id: 1, kind: :crypto, symbol: "BTC", quote_currency: "EUR"})
  @eth Listing.new(%{asset_id: 2, kind: :crypto, symbol: "ETH", quote_currency: "EUR"})

  describe "supports?/1" do
    test "free text yes, identifiers no" do
      assert CoinGecko.supports?({:text, "bitcoin"})
      refute CoinGecko.supports?({:isin, "IE00B4L5Y983"})
      refute CoinGecko.supports?({:wkn, "A0RPWH"})
    end

    test "crypto listings only" do
      assert CoinGecko.supports?(@btc)

      refute CoinGecko.supports?(
               Listing.new(%{kind: :etf, ticker: "EUNL", mic: "XETR", quote_currency: "EUR"})
             )
    end
  end

  describe "lookup/1" do
    test "maps search hits to symbol/name candidates, one per symbol" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/api/v3/search"
        assert conn.params["query"] == "bitcoin"
        json_fixture(conn, "coingecko_search.json")
      end)

      assert {:ok, candidates} = CoinGecko.lookup({:text, "bitcoin"})

      assert candidates == [
               %{symbol: "BTC", name: "Bitcoin"},
               %{symbol: "BCH", name: "Bitcoin Cash"},
               %{symbol: "BSV", name: "Bitcoin SV"}
             ]
    end
  end

  describe "daily_history/3" do
    test "a pinned symbol skips id resolution; the range is clamped and filtered" do
      from = ~D[2026-08-22]
      to = ~D[2026-08-24]

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/api/v3/coins/bitcoin/market_chart"
        assert conn.params["vs_currency"] == "eur"
        assert String.to_integer(conn.params["days"]) == Date.diff(Date.utc_today(), from)
        json_fixture(conn, "coingecko_market_chart.json")
      end)

      assert {:ok, entries} = CoinGecko.daily_history(@btc, from, to)

      # Fixture spans 08-21..08-25 (with a same-day partial); only the asked
      # window remains.
      assert Enum.map(entries, & &1.date) == [~D[2026-08-22], ~D[2026-08-23], ~D[2026-08-24]]
      assert Enum.all?(entries, &match?(%Decimal{}, &1.price))
    end

    test "an unpinned symbol resolves its coin id through /search first" do
      test_pid = self()

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        case conn.request_path do
          "/api/v3/search" ->
            send(test_pid, {:searched, conn.params["query"]})
            json_fixture(conn, "coingecko_search.json")

          "/api/v3/coins/bitcoin-cash/market_chart" ->
            json_fixture(conn, "coingecko_market_chart.json")
        end
      end)

      bch = Listing.new(%{asset_id: 3, kind: :crypto, symbol: "BCH", quote_currency: "EUR"})

      assert {:ok, _entries} = CoinGecko.daily_history(bch, ~D[2026-08-21], ~D[2026-08-25])
      assert_received {:searched, "BCH"}
    end

    test "a symbol CoinGecko does not know is an error" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_fixture(conn, "coingecko_search.json")
      end)

      xyz = Listing.new(%{asset_id: 4, kind: :crypto, symbol: "XYZ", quote_currency: "EUR"})

      assert {:error, {:unknown_symbol, "XYZ"}} =
               CoinGecko.daily_history(xyz, ~D[2026-08-21], ~D[2026-08-25])
    end
  end

  describe "fetch_quotes/1" do
    test "one batched simple/price call, keyed back by asset id" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/api/v3/simple/price"
        assert conn.params["ids"] == "bitcoin,ethereum"
        assert conn.params["vs_currencies"] == "eur"
        json_fixture(conn, "coingecko_simple_price.json")
      end)

      assert {:ok, quotes} = CoinGecko.fetch_quotes([@btc, @eth])

      assert %{price: btc_price, at: %DateTime{}, currency: "EUR"} = quotes[1]
      assert Decimal.equal?(btc_price, Decimal.new(67_611))
      assert Decimal.equal?(quotes[2].price, Decimal.new("2114.63"))
    end

    test "fetch_quote/1 answers for a single listing" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_fixture(conn, "coingecko_simple_price.json")
      end)

      assert {:ok, %{price: price}} = CoinGecko.fetch_quote(@btc)
      assert Decimal.equal?(price, Decimal.new(67_611))
    end

    test "rate limiting is surfaced" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

      assert {:error, :rate_limited} = CoinGecko.fetch_quotes([@btc])
    end
  end
end
