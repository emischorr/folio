defmodule Folio.MarketData.Sources.BoerseFrankfurtTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.MarketData.Listing
  alias Folio.MarketData.Sources.BoerseFrankfurt

  @listing Listing.new(%{
             asset_id: 1,
             kind: :etf,
             ticker: "EUNL",
             mic: "XETR",
             isin: "IE00B4L5Y983",
             quote_currency: "EUR"
           })

  describe "supports?/1" do
    test "securities with an ISIN on XETR or XFRA" do
      assert BoerseFrankfurt.supports?(@listing)
      assert BoerseFrankfurt.supports?(%{@listing | mic: "XFRA"})
    end

    test "declines crypto, missing ISIN and other venues" do
      refute BoerseFrankfurt.supports?(
               Listing.new(%{kind: :crypto, symbol: "BTC", quote_currency: "EUR"})
             )

      refute BoerseFrankfurt.supports?(%{@listing | isin: nil})
      refute BoerseFrankfurt.supports?(%{@listing | mic: "XSTU"})
    end
  end

  describe "fetch_quote/1" do
    test "reads lastPrice and takes the currency from the venue" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.host == "api.boerse-frankfurt.de"
        assert conn.request_path == "/v1/data/quote_box/single"
        assert conn.params["isin"] == "IE00B4L5Y983"
        assert conn.params["mic"] == "XETR"
        json_fixture(conn, "boerse_frankfurt_quote_box.json")
      end)

      assert {:ok, %{price: price, at: %DateTime{}, currency: "EUR"}} =
               BoerseFrankfurt.fetch_quote(@listing)

      assert Decimal.equal?(price, Decimal.new("127.235"))
    end

    test "an empty object (the endpoint's silent no) is :no_quote" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 200) end)

      assert {:error, :no_quote} = BoerseFrankfurt.fetch_quote(@listing)
    end

    test "rate limiting is surfaced" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

      assert {:error, :rate_limited} = BoerseFrankfurt.fetch_quote(@listing)
    end
  end
end
