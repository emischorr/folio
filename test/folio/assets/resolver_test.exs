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

    candidates = Assets.resolve("bitcoin").candidates

    assert [%Candidate{local_asset_id: local_id} | remote] = candidates
    assert local_id == local.id
    refute Enum.any?(remote, &(&1.price_source == :coingecko and &1.source_id == "bitcoin"))
    assert Enum.any?(remote, &(&1.source_id == "bitcoin-cash"))
  end

  test "crypto candidates map to CoinGecko with EUR quotes" do
    stub_remote_search()

    assert %Candidate{} =
             candidate = Enum.find(Assets.resolve("bitcoin").candidates, &(&1.kind == :crypto))

    assert candidate.price_source == :coingecko
    assert candidate.quote_currency == "EUR"
    assert candidate.symbol == "BTC"
  end

  test "equity candidates are enriched with currency and full exchange name from chart meta" do
    stub_remote_search()

    candidates = Assets.resolve("nvidia").candidates
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

    nvda = Enum.find(Assets.resolve("nvidia").candidates, &(&1.symbol == "NVDA"))
    assert nvda.quote_currency == nil
    assert nvda.exchange == "NASDAQ"
  end

  test "remote outage degrades to local-only results" do
    local = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 500) end)

    assert [%Candidate{local_asset_id: local_id}] = Assets.resolve("bitcoin").candidates
    assert local_id == local.id
  end

  test "creating an asset from a candidate stores the source mapping" do
    stub_remote_search()

    nvda = Enum.find(Assets.resolve("nvidia").candidates, &(&1.symbol == "NVDA"))
    assert {:ok, asset} = Assets.create_asset(Candidate.to_attrs(nvda))
    assert asset.price_source == :yahoo
    assert asset.source_id == "NVDA"
    assert asset.quote_currency == "USD"
  end

  describe "identifier queries" do
    test "an ISIN the equity provider resolves directly is stamped onto every candidate" do
      Req.Test.stub(Folio.Clients, fn conn ->
        case conn.request_path do
          "/v1/finance/search" ->
            assert conn.params["q"] == "DE000EWG2LD7"
            json_fixture(conn, "yahoo_search.json")

          "/v8/finance/chart/" <> _symbol ->
            json_fixture(conn, "yahoo_chart_nvda.json")
        end
      end)

      candidates = Assets.resolve("DE000EWG2LD7").candidates

      assert candidates != []
      assert Enum.all?(candidates, &(&1.isin == "DE000EWG2LD7"))
      # An ISIN is never a coin, so the crypto provider is not consulted.
      refute Enum.any?(candidates, &(&1.price_source == :coingecko))
    end

    test "an ISIN the equity provider cannot resolve falls back to the security-id provider" do
      Req.Test.stub(Folio.Clients, fn conn ->
        case {conn.request_path, conn.params["q"]} do
          {"/v3/mapping", _query} -> json_fixture(conn, "openfigi_isin.json")
          {"/v1/finance/search", "IE00B3WJKG14"} -> json_body(conn, ~s({"quotes":[]}))
          {"/v1/finance/search", ticker} -> json_body(conn, ticker_search(ticker))
          {"/v8/finance/chart/" <> _symbol, _query} -> json_fixture(conn, "yahoo_chart_nvda.json")
        end
      end)

      candidates = Assets.resolve("IE00B3WJKG14").candidates

      assert Enum.map(candidates, & &1.symbol) == ["IUIT.L", "QDVE.DE"]
      assert Enum.all?(candidates, &(&1.isin == "IE00B3WJKG14"))
    end

    test "a WKN resolves through the security-id provider and keeps plain-text hits" do
      Req.Test.stub(Folio.Clients, fn conn ->
        case {conn.request_path, conn.params["q"]} do
          {"/api/v3/search", _query} -> json_body(conn, ~s({"coins":[]}))
          {"/v3/mapping", _query} -> json_fixture(conn, "openfigi_isin.json")
          {"/v1/finance/search", "A142N1"} -> json_body(conn, ~s({"quotes":[]}))
          {"/v1/finance/search", ticker} -> json_body(conn, ticker_search(ticker))
          {"/v8/finance/chart/" <> _symbol, _query} -> json_fixture(conn, "yahoo_chart_nvda.json")
        end
      end)

      candidates = Assets.resolve("A142N1").candidates

      assert Enum.map(candidates, & &1.symbol) == ["IUIT.L", "QDVE.DE"]
      assert Enum.all?(candidates, &(&1.wkn == "A142N1"))
      assert Enum.all?(candidates, &is_nil(&1.isin))
    end

    test "a security-id outage still yields the equity provider's own ISIN hits" do
      Req.Test.stub(Folio.Clients, fn conn ->
        case conn.request_path do
          "/v3/mapping" -> json_body(conn, "[]", 500)
          "/v1/finance/search" -> json_fixture(conn, "yahoo_search.json")
          "/v8/finance/chart/" <> _symbol -> json_fixture(conn, "yahoo_chart_nvda.json")
        end
      end)

      assert Assets.resolve("DE000EWG2LD7").candidates != []
    end
  end

  describe "unsearchable fund names" do
    test "an empty result retries with the noise words stripped" do
      test_pid = self()

      Req.Test.stub(Folio.Clients, fn conn ->
        case conn.request_path do
          "/api/v3/search" ->
            json_body(conn, ~s({"coins":[]}))

          "/v1/finance/search" ->
            send(test_pid, {:searched, conn.params["q"]})

            if conn.params["q"] == "SPDR MSCI All Country World" do
              json_fixture(conn, "yahoo_search.json")
            else
              json_body(conn, ~s({"quotes":[]}))
            end

          "/v8/finance/chart/" <> _symbol ->
            json_fixture(conn, "yahoo_chart_nvda.json")
        end
      end)

      assert Assets.resolve("SPDR MSCI All Country World UCITS ETF (Acc)").candidates != []

      assert_received {:searched, "SPDR MSCI All Country World UCITS ETF (Acc)"}
      assert_received {:searched, "SPDR MSCI All Country World"}
    end

    test "a non-empty result never triggers a retry" do
      test_pid = self()

      Req.Test.stub(Folio.Clients, fn conn ->
        case conn.request_path do
          "/api/v3/search" ->
            json_body(conn, ~s({"coins":[]}))

          "/v1/finance/search" ->
            send(test_pid, {:searched, conn.params["q"]})
            json_fixture(conn, "yahoo_search.json")

          "/v8/finance/chart/" <> _symbol ->
            json_fixture(conn, "yahoo_chart_nvda.json")
        end
      end)

      Assets.resolve("nvidia UCITS ETF").candidates

      assert_received {:searched, "nvidia UCITS ETF"}
      refute_received {:searched, "nvidia"}
    end
  end

  describe "provider health" do
    test "a healthy search reports :ok" do
      stub_remote_search()

      assert %{status: :ok} = Assets.resolve("nvidia")
    end

    test "a rate-limited provider is reported, and local matches still come through" do
      local = crypto_asset_fixture(%{name: "Bitcoin", symbol: "BTC"})
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 429) end)

      assert %{candidates: [candidate], status: :rate_limited} = Assets.resolve("bitcoin")
      assert candidate.local_asset_id == local.id
    end

    test "any other provider failure reports :unavailable" do
      Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 500) end)

      assert %{candidates: [], status: :unavailable} = Assets.resolve("bitcoin")
    end

    test "rate limiting outranks a plain failure" do
      Req.Test.stub(Folio.Clients, fn conn ->
        case conn.request_path do
          "/api/v3/search" -> json_body(conn, "{}", 500)
          "/v1/finance/search" -> json_body(conn, "{}", 429)
        end
      end)

      assert %{status: :rate_limited} = Assets.resolve("nvidia")
    end
  end

  defp ticker_search(ticker) do
    symbol = if ticker == "IUIT", do: "IUIT.L", else: "QDVE.DE"

    ~s({"quotes":[{"quoteType":"ETF","symbol":"#{symbol}","longname":"iShares S&P 500 IT",
      "exchDisp":"Listing"},{"quoteType":"ETF","symbol":"OTHER.L","longname":"Unrelated",
      "exchDisp":"Listing"}]})
  end
end
