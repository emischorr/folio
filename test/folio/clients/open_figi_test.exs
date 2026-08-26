defmodule Folio.Clients.OpenFigiTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.Clients.OpenFigi

  test "lookup/2 posts an ISIN mapping request and dedupes tickers across venues" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/v3/mapping"
      json_fixture(conn, "openfigi_isin.json")
    end)

    assert {:ok, hits} = OpenFigi.lookup(:isin, "IE00B3WJKG14")

    assert hits == [
             %{ticker: "IUIT", exchange_code: "LN", name: "ISHARES S&P 500 IT SECTOR"},
             %{ticker: "QDVE", exchange_code: "GR", name: "ISHARES S&P 500 IT SECTOR"}
           ]
  end

  test "lookup/2 maps a WKN through the Wertpapier id type" do
    Req.Test.stub(Folio.Clients, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert [%{"idType" => "ID_WERTPAPIER", "idValue" => "EWG2LD"}] = Jason.decode!(body)
      json_fixture(conn, "openfigi_isin.json")
    end)

    assert {:ok, [_first | _rest]} = OpenFigi.lookup(:wkn, "EWG2LD")
  end

  test "an unknown identifier is an empty result, not an error" do
    Req.Test.stub(Folio.Clients, fn conn ->
      json_fixture(conn, "openfigi_not_found.json")
    end)

    assert {:ok, []} = OpenFigi.lookup(:isin, "DE0000000000")
  end

  test "rate limiting is surfaced" do
    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "[]", 429) end)

    assert {:error, :rate_limited} = OpenFigi.lookup(:isin, "IE00B3WJKG14")
  end
end
