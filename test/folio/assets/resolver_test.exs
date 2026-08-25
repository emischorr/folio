defmodule Folio.Assets.ResolverTest do
  use Folio.DataCase, async: true

  import Folio.ApiStubCase
  import Folio.AssetsFixtures

  alias Folio.Assets
  alias Folio.Assets.Candidate

  defp stub_remote_search do
    Req.Test.stub(Folio.Clients, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.coingecko.com", "/api/v3/search"} ->
          json_fixture(conn, "coingecko_search.json")

        {"query1.finance.yahoo.com", "/v1/finance/search"} ->
          json_fixture(conn, "yahoo_search.json")

        {"query1.finance.yahoo.com", "/v8/finance/chart/" <> _symbol} ->
          json_fixture(conn, "yahoo_chart_nvda.json")
      end
    end)
  end

  test "local matches come first and are not duplicated by remote hits" do
    local = crypto_asset_fixture(%{source_id: "bitcoin", name: "Bitcoin", symbol: "BTC"})
    stub_remote_search()

    candidates = Assets.resolve("bitcoin")

    assert [%Candidate{local_asset_id: local_id} | remote] = candidates
    assert local_id == local.id
    refute Enum.any?(remote, &(&1.price_source == :coingecko and &1.source_id == "bitcoin"))
    assert Enum.any?(remote, &(&1.source_id == "bitcoin-cash"))
  end

  test "crypto candidates map to CoinGecko with EUR quotes" do
    stub_remote_search()

    assert %Candidate{} = candidate = Enum.find(Assets.resolve("bitcoin"), &(&1.kind == :crypto))
    assert candidate.price_source == :coingecko
    assert candidate.quote_currency == "EUR"
    assert candidate.symbol == "BTC"
  end

  test "equity candidates are enriched with currency and full exchange name from chart meta" do
    stub_remote_search()

    candidates = Assets.resolve("nvidia")
    nvda = Enum.find(candidates, &(&1.symbol == "NVDA"))

    assert nvda.quote_currency == "USD"
    assert nvda.exchange == "NasdaqGS"
    assert nvda.price_source == :yahoo
    assert nvda.source_id == "NVDA"
    assert Candidate.label(nvda) == "NVIDIA Corporation · NasdaqGS · USD"
  end

  test "failed enrichment keeps the candidate without a currency" do
    Req.Test.stub(Folio.Clients, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.coingecko.com", _path} -> json_body(conn, ~s({"coins":[]}))
        {_host, "/v1/finance/search"} -> json_fixture(conn, "yahoo_search.json")
        {_host, "/v8/finance/chart/" <> _symbol} -> json_body(conn, "{}", 500)
      end
    end)

    nvda = Enum.find(Assets.resolve("nvidia"), &(&1.symbol == "NVDA"))
    assert nvda.quote_currency == nil
    assert nvda.exchange == "NASDAQ"
  end

  test "remote outage degrades to local-only results" do
    local = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 500) end)

    assert [%Candidate{local_asset_id: local_id}] = Assets.resolve("bitcoin")
    assert local_id == local.id
  end

  test "creating an asset from a candidate stores the source mapping" do
    stub_remote_search()

    nvda = Enum.find(Assets.resolve("nvidia"), &(&1.symbol == "NVDA"))
    assert {:ok, asset} = Assets.create_asset(Candidate.to_attrs(nvda))
    assert asset.price_source == :yahoo
    assert asset.source_id == "NVDA"
    assert asset.quote_currency == "USD"
  end
end
