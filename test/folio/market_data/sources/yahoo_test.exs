defmodule Folio.MarketData.Sources.YahooTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.MarketData.Listing
  alias Folio.MarketData.Sources.Yahoo

  @nvda Listing.new(%{
          asset_id: 1,
          kind: :stock,
          ticker: "NVDA",
          mic: "XNAS",
          isin: "US67066G1040",
          quote_currency: "USD"
        })

  @eunl Listing.new(%{
          asset_id: 2,
          kind: :etf,
          ticker: "EUNL",
          mic: "XETR",
          isin: "IE00B4L5Y983",
          quote_currency: "EUR"
        })

  describe "supports?/1" do
    test "lookup inputs: ISIN and text yes, WKN no" do
      assert Yahoo.supports?({:isin, "US67066G1040"})
      assert Yahoo.supports?({:text, "nvidia"})
      refute Yahoo.supports?({:wkn, "A0RPWH"})
    end

    test "listings: securities whose MIC has a suffix mapping" do
      assert Yahoo.supports?(@nvda)
      assert Yahoo.supports?(@eunl)
      refute Yahoo.supports?(Listing.new(%{kind: :crypto, symbol: "BTC", quote_currency: "EUR"}))
      refute Yahoo.supports?(%{@eunl | mic: nil})
      refute Yahoo.supports?(%{@eunl | ticker: nil})
    end

    test "a per-ISIN symbol override makes an otherwise unmappable listing supported" do
      Application.put_env(:folio, Yahoo, symbol_overrides: %{"IE00B4L5Y983" => "EUNL.DE"})
      on_exit(fn -> Application.put_env(:folio, Yahoo, symbol_overrides: %{}) end)

      assert Yahoo.supports?(%{@eunl | ticker: nil, mic: nil})
    end
  end

  describe "lookup/1" do
    test "maps search hits to vendor-neutral candidates, dropping unmappable venues" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/v1/finance/search"
        assert conn.params["q"] == "nvidia"
        json_fixture(conn, "yahoo_search.json")
      end)

      assert {:ok, candidates} = Yahoo.lookup({:text, "nvidia"})

      # NVDX (BATS) and NVDC34.SA (São Paulo) have no MIC mapping and are dropped.
      assert Enum.map(candidates, &{&1.ticker, &1.mic, &1.kind, &1.quote_currency}) == [
               {"NVDA", "XNAS", :stock, "USD"},
               {"NVHE-U", "XTSE", :etf, "CAD"},
               {"EWG2", "XSTU", :etf, "EUR"}
             ]

      assert Enum.all?(candidates, &is_nil(&1.isin))
    end

    test "an ISIN query stamps the ISIN onto every candidate" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_fixture(conn, "yahoo_search_isin.json")
      end)

      assert {:ok, [candidate]} = Yahoo.lookup({:isin, "DE000EWG2LD7"})
      assert %{ticker: "EWG2", mic: "XSTU", kind: :etf, isin: "DE000EWG2LD7"} = candidate
    end

    test "an unsearchable official fund name is retried with the noise trimmed" do
      full_name = "EUWAX Gold II UCITS ETF (Acc)"

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        case conn.params["q"] do
          ^full_name -> json_body(conn, ~s({"quotes": []}), 200)
          "EUWAX Gold II" -> json_fixture(conn, "yahoo_search_isin.json")
        end
      end)

      assert {:ok, [%{ticker: "EWG2"}]} = Yahoo.lookup({:text, full_name})
    end

    test "rate limiting is surfaced, including Yahoo's own 999" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 999) end)

      assert {:error, :rate_limited} = Yahoo.lookup({:text, "nvidia"})
    end
  end

  describe "daily_history/3" do
    test "builds the suffixed symbol and maps the chart to dated Decimal closes" do
      from = ~D[2026-08-17]
      to = ~D[2026-08-26]

      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        assert conn.params["interval"] == "1d"

        assert String.to_integer(conn.params["period1"]) ==
                 DateTime.to_unix(~U[2026-08-17 00:00:00Z])

        assert String.to_integer(conn.params["period2"]) ==
                 DateTime.to_unix(~U[2026-08-27 00:00:00Z])

        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert {:ok, entries} = Yahoo.daily_history(@nvda, from, to)

      assert length(entries) == 5
      assert entries == Enum.sort_by(entries, & &1.date, Date)
      assert %{price: %Decimal{} = first} = hd(entries)
      assert Decimal.equal?(first, Decimal.new("217.55999755859375"))
    end

    test "a European listing gets its MIC suffix" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/v8/finance/chart/EUNL.DE"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert {:ok, _entries} = Yahoo.daily_history(@eunl, ~D[2026-08-17], ~D[2026-08-26])
    end
  end

  describe "fetch_quote/1" do
    test "reads price, time and currency from the chart meta" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.request_path == "/v8/finance/chart/NVDA"
        assert conn.params["range"] == "1d"
        json_fixture(conn, "yahoo_chart_nvda.json")
      end)

      assert {:ok, %{price: price, at: at, currency: "USD"}} = Yahoo.fetch_quote(@nvda)
      assert Decimal.equal?(price, Decimal.new("213.44"))
      assert at == DateTime.from_unix!(1_787_667_142)
    end

    test "a provider error in the chart body is a failure, not a crash" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_body(conn, ~s({"chart": {"result": null, "error": {"code": "Not Found"}}}), 200)
      end)

      assert {:error, {:provider, %{"code" => "Not Found"}}} = Yahoo.fetch_quote(@nvda)
    end
  end
end
