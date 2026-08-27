defmodule Folio.Assets.ResolverTest do
  use Folio.DataCase, async: true

  @moduletag :capture_log

  import Folio.ApiStubCase
  import Folio.AssetsFixtures

  alias Folio.Assets
  alias Folio.Assets.Candidate

  defp stub_remote_search do
    Req.Test.stub(Folio.MarketData.Sources, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.coingecko.com", "/api/v3/search"} ->
          json_fixture(conn, "coingecko_search.json")

        {"query1.finance.yahoo.com", "/v1/finance/search"} ->
          json_fixture(conn, "yahoo_search.json")

        {"api.openfigi.com", "/v3/mapping"} ->
          json_fixture(conn, "openfigi_isin.json")
      end
    end)
  end

  test "local matches come first and are not duplicated by remote hits" do
    local = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
    stub_remote_search()

    candidates = Assets.resolve("bitcoin").candidates

    assert [%Candidate{local_asset_id: local_id} | remote] = candidates
    assert local_id == local.id
    refute Enum.any?(remote, &(&1.kind == :crypto and &1.symbol == "BTC"))
    assert Enum.any?(remote, &(&1.kind == :crypto and &1.symbol == "BCH"))
  end

  test "crypto candidates carry the symbol and default to EUR quotes" do
    stub_remote_search()

    assert %Candidate{} =
             candidate = Enum.find(Assets.resolve("bitcoin").candidates, &(&1.kind == :crypto))

    assert candidate.symbol == "BTC"
    assert candidate.quote_currency == "EUR"
    assert candidate.local_asset_id == nil
  end

  test "security candidates carry vendor-neutral identity with the venue's currency" do
    stub_remote_search()

    candidates = Assets.resolve("nvidia").candidates
    nvda = Enum.find(candidates, &(&1.ticker == "NVDA"))

    assert nvda.kind == :stock
    assert nvda.mic == "XNAS"
    assert nvda.quote_currency == "USD"
    assert nvda.isin == nil
  end

  test "an ISIN resolves through the identifier chain and is stamped onto candidates" do
    Req.Test.stub(Folio.MarketData.Sources, fn conn ->
      assert conn.host == "api.openfigi.com"
      json_fixture(conn, "openfigi_isin.json")
    end)

    %{candidates: candidates, status: :ok} = Assets.resolve("IE00B3WJKG14")

    assert candidates != []
    assert Enum.all?(candidates, &(&1.isin == "IE00B3WJKG14"))
    assert Enum.any?(candidates, &(&1.ticker == "QDVE" and &1.mic == "XETR"))
  end

  test "a WKN goes through the identifier chain and keeps text hits" do
    Req.Test.stub(Folio.MarketData.Sources, fn conn ->
      case conn.host do
        "api.openfigi.com" -> json_fixture(conn, "openfigi_wkn.json")
        "api.coingecko.com" -> json_fixture(conn, "coingecko_search.json")
        "query1.finance.yahoo.com" -> json_fixture(conn, "yahoo_search.json")
      end
    end)

    %{candidates: candidates, status: :ok} = Assets.resolve("A0RPWH")

    # From OpenFIGI (no ISIN for a WKN query)...
    assert Enum.any?(candidates, &(&1.ticker == "EUNL" and is_nil(&1.isin)))
    # ...plus plain-text hits, since six characters may just be a ticker.
    assert Enum.any?(candidates, &(&1.ticker == "NVDA"))
  end

  test "remote candidates dedupe by identity across chains" do
    stub_remote_search()

    candidates = Assets.resolve("nvidia").candidates
    identities = Enum.map(candidates, &Candidate.identity/1)
    assert identities == Enum.uniq(identities)
  end

  test "a rate-limited provider degrades to local hits with status :rate_limited" do
    local = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
    Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 429) end)

    assert %{candidates: [%Candidate{local_asset_id: local_id}], status: :rate_limited} =
             Assets.resolve("bitcoin")

    assert local_id == local.id
  end

  test "a failing provider degrades to status :unavailable" do
    Req.Test.stub(Folio.MarketData.Sources, fn conn -> json_body(conn, "{}", 500) end)

    assert %{candidates: [], status: :unavailable} = Assets.resolve("bitcoin")
  end

  test "creating an asset from a security candidate stores its identity" do
    Req.Test.stub(Folio.MarketData.Sources, fn conn ->
      case conn.host do
        "api.openfigi.com" -> json_fixture(conn, "openfigi_isin.json")
        _other -> json_body(conn, ~s({"quotes": []}), 200)
      end
    end)

    candidate =
      Enum.find(Assets.resolve("IE00B3WJKG14").candidates, &(&1.mic == "XETR"))

    assert {:ok, asset} = Assets.create_asset(Candidate.to_attrs(candidate))
    assert asset.ticker == "QDVE"
    assert asset.mic == "XETR"
    assert asset.isin == "IE00B3WJKG14"
    assert asset.quote_currency == "EUR"
  end
end
