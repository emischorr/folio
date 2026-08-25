defmodule Folio.Clients.FrankfurterTest do
  use ExUnit.Case, async: true

  import Folio.ApiStubCase

  alias Folio.Clients.Frankfurter

  test "latest_rates/1 parses the dated EUR-pivot rates" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.host == "api.frankfurter.dev"
      assert conn.request_path == "/v1/latest"
      assert conn.params["base"] == "EUR"
      json_fixture(conn, "frankfurter_latest.json")
    end)

    assert {:ok, %{date: ~D[2026-08-25], rates: rates}} = Frankfurter.latest_rates(["USD", "GBP"])
    assert Decimal.eq?(rates["USD"], "1.1662")
    assert Decimal.eq?(rates["GBP"], "0.8555")
  end

  test "historical_rates/3 returns ascending dated entries" do
    Req.Test.stub(Folio.Clients, fn conn ->
      assert conn.request_path == "/v1/2026-08-17..2026-08-21"
      json_fixture(conn, "frankfurter_series.json")
    end)

    assert {:ok, entries} = Frankfurter.historical_rates(["USD"], ~D[2026-08-17], ~D[2026-08-21])
    assert length(entries) == 5
    assert List.first(entries).date == ~D[2026-08-17]
    assert entries == Enum.sort_by(entries, & &1.date, Date)
    assert Enum.all?(entries, &match?(%Decimal{}, &1.rates["USD"]))
  end

  test "unexpected statuses become error tuples" do
    Req.Test.stub(Folio.Clients, fn conn -> json_body(conn, "{}", 404) end)

    assert {:error, {:http_status, 404}} = Frankfurter.latest_rates(["XXX"])
  end
end
