defmodule Folio.MarketData.Sources.TradegateTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.MarketData.Listing
  alias Folio.MarketData.Sources.Tradegate

  @listing Listing.new(%{
             asset_id: 1,
             kind: :etf,
             ticker: "EUNL",
             mic: "XETR",
             isin: "IE00B4L5Y983",
             quote_currency: "EUR"
           })

  describe "supports?/1" do
    test "EUR securities with an ISIN on German retail and Euronext venues" do
      assert Tradegate.supports?(@listing)
      assert Tradegate.supports?(%{@listing | mic: "XAMS"})
    end

    test "declines crypto, missing ISIN, non-EUR and unsupported venues" do
      refute Tradegate.supports?(
               Listing.new(%{kind: :crypto, symbol: "BTC", quote_currency: "EUR"})
             )

      refute Tradegate.supports?(%{@listing | isin: nil})
      refute Tradegate.supports?(%{@listing | quote_currency: "USD"})
      refute Tradegate.supports?(%{@listing | mic: "XNAS"})
      refute Tradegate.supports?(%{@listing | mic: "XLON"})
    end
  end

  describe "fetch_quote/1" do
    test "reads the last price as a Decimal from the JSON-float payload" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.host == "www.tradegatebsx.com"
        assert conn.request_path == "/refresh.php"
        assert conn.params["isin"] == "IE00B4L5Y983"
        json_fixture(conn, "tradegate_refresh.json")
      end)

      assert {:ok, %{price: price, at: %DateTime{}, currency: "EUR"}} =
               Tradegate.fetch_quote(@listing)

      assert Decimal.equal?(price, Decimal.new("127.185"))
    end

    test "falls back to the close when last is zero (pre-open)" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_body(conn, ~s({"last": 0, "close": 126.77}), 200)
      end)

      assert {:ok, %{price: price}} = Tradegate.fetch_quote(@listing)
      assert Decimal.equal?(price, Decimal.new("126.77"))
    end

    test "no positive price at all is :no_quote, so the chain falls through" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_body(conn, ~s({"last": 0, "close": 0}), 200)
      end)

      assert {:error, :no_quote} = Tradegate.fetch_quote(@listing)
    end

    test "rate limiting is surfaced" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

      assert {:error, :rate_limited} = Tradegate.fetch_quote(@listing)
    end
  end
end
