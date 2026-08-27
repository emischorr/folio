defmodule Folio.MarketData.Sources.OpenFigiTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.MarketData.Sources.OpenFigi

  describe "supports?/1" do
    test "identifiers yes, free text no" do
      assert OpenFigi.supports?({:isin, "IE00B3WJKG14"})
      assert OpenFigi.supports?({:wkn, "A0RPWH"})
      refute OpenFigi.supports?({:text, "nvidia"})
    end
  end

  describe "lookup/1" do
    test "maps an ISIN to per-venue candidates with MICs and the input ISIN stamped" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v3/mapping"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [%{"idType" => "ID_ISIN", "idValue" => "IE00B3WJKG14"}] = Jason.decode!(body)
        json_fixture(conn, "openfigi_isin.json")
      end)

      assert {:ok, candidates} = OpenFigi.lookup({:isin, "IE00B3WJKG14"})

      assert candidates == [
               %{
                 kind: :etf,
                 isin: "IE00B3WJKG14",
                 mic: "XLON",
                 ticker: "IUIT",
                 name: "ISHARES S&P 500 IT SECTOR",
                 quote_currency: "GBP"
               },
               %{
                 kind: :etf,
                 isin: "IE00B3WJKG14",
                 mic: "XETR",
                 ticker: "QDVE",
                 name: "ISHARES S&P 500 IT SECTOR",
                 quote_currency: "EUR"
               },
               %{
                 kind: :etf,
                 isin: "IE00B3WJKG14",
                 mic: "XFRA",
                 ticker: "QDVE",
                 name: "ISHARES S&P 500 IT SECTOR",
                 quote_currency: "EUR"
               }
             ]
    end

    test "a WKN maps through ID_WERTPAPIER, carries no ISIN, and drops unmappable venues" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert [%{"idType" => "ID_WERTPAPIER", "idValue" => "A0RPWH"}] = Jason.decode!(body)
        json_fixture(conn, "openfigi_wkn.json")
      end)

      assert {:ok, candidates} = OpenFigi.lookup({:wkn, "A0RPWH"})

      # The QX record is dropped: its exchange code has no MIC mapping.
      assert Enum.map(candidates, &{&1.ticker, &1.mic}) == [{"EUNL", "XETR"}, {"EUNL", "XFRA"}]
      assert Enum.all?(candidates, &is_nil(&1.isin))
    end

    test "an unknown identifier is an empty result, not an error" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn ->
        json_fixture(conn, "openfigi_not_found.json")
      end)

      assert {:ok, []} = OpenFigi.lookup({:isin, "DE0000000000"})
    end

    test "rate limiting is surfaced" do
      Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "[]", 429) end)

      assert {:error, :rate_limited} = OpenFigi.lookup({:isin, "IE00B3WJKG14"})
    end
  end
end
