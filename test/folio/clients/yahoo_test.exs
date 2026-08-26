defmodule Folio.Clients.YahooTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.Clients.Yahoo

  test "search/1 parses equity, ETF and fund hits - without any currency field - and sends a browser UA" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/v1/finance/search"
      assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")
      assert user_agent =~ "Mozilla"
      json_fixture(conn, "yahoo_search.json")
    end)

    assert {:ok, hits} = Yahoo.search("nvidia")

    assert [
             %{symbol: "NVDA", name: "NVIDIA Corporation", exchange: "NASDAQ", kind: :stock}
             | _rest
           ] = hits

    assert Enum.map(hits, & &1.kind) == [:stock, :etf, :etf, :stock, :etf]
    # Yahoo types European fund listings as MUTUALFUND; they must survive as ETFs.
    assert Enum.any?(hits, &(&1.symbol == "EWG2.SG" and &1.kind == :etf))
    # The NVDX row has no longname; the shortname fallback applies.
    assert Enum.any?(hits, &(&1.symbol == "NVDX" and is_binary(&1.name)))
  end

  test "quote_meta/1 reads currency, full exchange name, and price from chart meta" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/v8/finance/chart/NVDA"
      json_fixture(conn, "yahoo_chart_nvda.json")
    end)

    assert {:ok, meta} = Yahoo.quote_meta("NVDA")
    assert meta.currency == "USD"
    assert meta.exchange == "NasdaqGS"
    assert Decimal.eq?(meta.price, "213.44")
  end

  test "daily_history/2 zips timestamps with closes into dated Decimals" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/v8/finance/chart/NVDA"
      assert conn.params["period1"]
      json_fixture(conn, "yahoo_chart_nvda.json")
    end)

    assert {:ok, entries} = Yahoo.daily_history("NVDA", ~D[2026-08-14])
    assert length(entries) == 5
    assert Enum.all?(entries, &match?(%Decimal{}, &1.price))
    assert entries == Enum.sort_by(entries, & &1.date, Date)
  end

  test "daily_history/2 drops null closes" do
    body = ~s({"chart":{"result":[{"meta":{"currency":"USD"},"timestamp":[1787146200,1787232600],
      "indicators":{"quote":[{"close":[null,100.5]}]}}]}})

    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, body) end)

    assert {:ok, [entry]} = Yahoo.daily_history("NVDA", ~D[2026-08-14])
    assert Decimal.eq?(entry.price, "100.5")
  end

  test "a chart-level provider error is surfaced" do
    body =
      ~s({"chart":{"result":null,"error":{"code":"Not Found","description":"No data found"}}})

    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, body, 404) end)

    assert {:error, {:http_status, 404}} = Yahoo.quote_meta("NOPE")

    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, body) end)
    assert {:error, {:provider, %{"code" => "Not Found"}}} = Yahoo.quote_meta("NOPE")
  end
end
