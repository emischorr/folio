defmodule Folio.MarketData.MarketsTest do
  use ExUnit.Case, async: true

  alias Folio.MarketData.Markets

  describe "registry" do
    test "every market has complete fields and a unique MIC" do
      markets = Markets.all()

      assert length(markets) == length(Enum.uniq_by(markets, & &1.mic))

      for market <- markets do
        assert %{
                 mic: <<_::binary-size(4)>>,
                 name: name,
                 country: <<_::binary-size(2)>>,
                 currency: <<_::binary-size(3)>>,
                 timezone: timezone,
                 trading_hours: {%Time{} = open, %Time{} = close}
               } = market

        assert is_binary(name)
        assert {:ok, _} = DateTime.shift_zone(~U[2026-08-27 12:00:00Z], timezone)
        assert Time.compare(open, close) == :lt
      end
    end

    test "get/1 and mics/0" do
      assert %{name: "Xetra", currency: "EUR"} = Markets.get("XETR")
      assert Markets.get("XXXX") == nil
      assert "XETR" in Markets.mics()
    end

    test "name/1 falls back to the MIC for unknown venues" do
      assert Markets.name("XNAS") == "Nasdaq"
      assert Markets.name("XXXX") == "XXXX"
      assert Markets.name(nil) == nil
    end

    test "currency/1" do
      assert Markets.currency("XLON") == "GBP"
      assert Markets.currency("XXXX") == nil
      assert Markets.currency(nil) == nil
    end

    test "german_retail_mics/0 are all registered" do
      assert Markets.german_retail_mics() -- Markets.mics() == []
    end
  end

  describe "open?/2" do
    # 2026-08-26 is a Wednesday; 2026-08-29/30 are the weekend.

    test "Xetra session in CEST (UTC+2)" do
      # 09:00 local open -> 07:00 UTC; padding admits 06:45 UTC
      assert Markets.open?("XETR", ~U[2026-08-26 06:45:00Z])
      refute Markets.open?("XETR", ~U[2026-08-26 06:44:59Z])
      # 17:30 local close -> 15:30 UTC; padding admits 15:45 UTC
      assert Markets.open?("XETR", ~U[2026-08-26 15:45:00Z])
      refute Markets.open?("XETR", ~U[2026-08-26 15:45:01Z])
    end

    test "Xetra session in CET (UTC+1, winter)" do
      # 2026-01-14 is a Wednesday; 09:00 local -> 08:00 UTC
      assert Markets.open?("XETR", ~U[2026-01-14 08:00:00Z])
      refute Markets.open?("XETR", ~U[2026-01-14 07:30:00Z])
    end

    test "NYSE session crosses the UTC date line of its own day" do
      # 09:30 New York (EDT, UTC-4) -> 13:30 UTC
      assert Markets.open?("XNYS", ~U[2026-08-26 13:30:00Z])
      refute Markets.open?("XNYS", ~U[2026-08-26 13:00:00Z])
      # 16:00 close -> 20:00 UTC, padded to 20:15
      assert Markets.open?("XNYS", ~U[2026-08-26 20:15:00Z])
      refute Markets.open?("XNYS", ~U[2026-08-26 20:30:00Z])
    end

    test "weekends are closed even inside trading hours" do
      refute Markets.open?("XETR", ~U[2026-08-29 08:00:00Z])
      refute Markets.open?("XETR", ~U[2026-08-30 08:00:00Z])
    end

    test "weekday boundary respects the exchange's local day, not UTC" do
      # Friday 22:00 UTC is already Saturday 06:00 in Hong Kong -> closed;
      # Sunday 23:50 UTC is Monday 07:50 in Hong Kong but before the open.
      refute Markets.open?("XHKG", ~U[2026-08-28 22:00:00Z])
      refute Markets.open?("XHKG", ~U[2026-08-30 23:50:00Z])
      # Monday 01:30 UTC is Monday 09:30 in Hong Kong -> open
      assert Markets.open?("XHKG", ~U[2026-08-31 01:30:00Z])
    end

    test "unknown MIC is treated as always open" do
      assert Markets.open?("XXXX", ~U[2026-08-30 03:00:00Z])
      assert Markets.open?(nil, ~U[2026-08-30 03:00:00Z])
    end
  end
end
