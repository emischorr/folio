defmodule Folio.Analytics.EngineTest do
  use ExUnit.Case, async: true

  alias Folio.Analytics.Dataset
  alias Folio.Analytics.Engine

  # Fixture layout (all hand-checkable):
  #
  # Asset 1 "BTC", EUR-quoted. Daily closes Mon 2025-01-06 .. Fri 2025-01-10:
  # 100, 110, 120, 130, 140. No weekend rows.
  #
  # Asset 2 "NVDA", USD-quoted. Closes 2025-01-06: 50, 2025-01-07: 60.
  # EUR-pivot FX (1 EUR = rate USD): 2025-01-06: 1.25, 2025-01-07: 1.10,
  # nothing later (weekend-style gap).

  defp d(value), do: Decimal.new(value)

  defp midnight(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp btc_prices do
    [
      {~D[2025-01-06], "100"},
      {~D[2025-01-07], "110"},
      {~D[2025-01-08], "120"},
      {~D[2025-01-09], "130"},
      {~D[2025-01-10], "140"}
    ]
    |> Enum.map(fn {date, price} -> {midnight(date), d(price)} end)
    |> Enum.reverse()
  end

  defp nvda_prices do
    [{midnight(~D[2025-01-07]), d("60")}, {midnight(~D[2025-01-06]), d("50")}]
  end

  defp usd_fx do
    [{midnight(~D[2025-01-07]), d("1.10")}, {midnight(~D[2025-01-06]), d("1.25")}]
  end

  defp buy(asset_id, executed_at, quantity, price, opts \\ []) do
    txn(:buy, asset_id, executed_at, quantity, price, opts)
  end

  defp sell(asset_id, executed_at, quantity, price, opts \\ []) do
    txn(:sell, asset_id, executed_at, quantity, price, opts)
  end

  defp txn(type, asset_id, executed_at, quantity, price, opts) do
    %{
      asset_id: asset_id,
      type: type,
      executed_at: executed_at,
      quantity: d(quantity),
      price_per_unit: d(price),
      fee: d(Keyword.get(opts, :fee, "0")),
      currency: Keyword.get(opts, :currency, "EUR")
    }
  end

  defp eur_dataset(txns) do
    %Dataset{
      base_currency: "EUR",
      assets: %{1 => %{symbol: "BTC", name: "Bitcoin", quote_currency: "EUR"}},
      txns: txns,
      prices: %{1 => btc_prices()},
      fx: %{}
    }
  end

  defp usd_dataset(txns) do
    %Dataset{
      base_currency: "EUR",
      assets: %{2 => %{symbol: "NVDA", name: "NVIDIA", quote_currency: "USD"}},
      txns: txns,
      prices: %{2 => nvda_prices()},
      fx: %{"USD" => usd_fx()}
    }
  end

  defp assert_decimal(actual, expected) do
    assert Decimal.eq?(actual, Decimal.new(expected)),
           "expected #{inspect(actual)} to equal #{inspect(expected)}"
  end

  describe "value and holdings" do
    test "value uses the latest close at or before t" do
      dataset = eur_dataset([buy(1, ~U[2025-01-06 10:00:00Z], "2", "100", fee: "1")])

      assert_decimal(Engine.value_at(dataset, ~U[2025-01-08 12:00:00Z], "EUR"), "240")
      # Saturday: Friday's close serves the weekend.
      assert_decimal(Engine.value_at(dataset, ~U[2025-01-11 12:00:00Z], "EUR"), "280")
      # Before any transaction: zero.
      assert_decimal(Engine.value_at(dataset, ~U[2025-01-05 12:00:00Z], "EUR"), "0")
    end

    test "holdings accumulate signed quantities" do
      dataset =
        eur_dataset([
          buy(1, ~U[2025-01-06 10:00:00Z], "2", "100"),
          sell(1, ~U[2025-01-08 10:00:00Z], "0.5", "120")
        ])

      assert_decimal(Engine.holdings_at(dataset, ~U[2025-01-07 00:00:00Z])[1], "2")
      assert_decimal(Engine.holdings_at(dataset, ~U[2025-01-09 00:00:00Z])[1], "1.5")
    end

    test "a full sell drops the value to zero and realizes profit" do
      dataset =
        eur_dataset([
          buy(1, ~U[2025-01-06 10:00:00Z], "2", "100", fee: "1"),
          buy(1, ~U[2025-01-09 10:00:00Z], "1", "130"),
          sell(1, ~U[2025-01-10 09:00:00Z], "3", "140", fee: "2")
        ])

      now = ~U[2025-01-10 12:00:00Z]
      assert_decimal(Engine.value_at(dataset, now, "EUR"), "0")
      # Invested 201 + 130 = 331; proceeds 420 - 2 = 418; profit 87.
      assert_decimal(Engine.cost_basis_at(dataset, now, "EUR"), "-87")

      [%{value: profit}] = Engine.profit_series(dataset, [now], "EUR")
      assert_decimal(profit, "87")
    end
  end

  describe "cost basis and window change" do
    test "fees are part of invested capital" do
      dataset = eur_dataset([buy(1, ~U[2025-01-06 10:00:00Z], "2", "100", fee: "1")])
      assert_decimal(Engine.cost_basis_at(dataset, ~U[2025-01-07 00:00:00Z], "EUR"), "201")
    end

    test "a buy inside the window is cashflow, not profit" do
      dataset =
        eur_dataset([
          buy(1, ~U[2025-01-06 10:00:00Z], "2", "100"),
          buy(1, ~U[2025-01-09 10:00:00Z], "1", "130")
        ])

      window_start = ~U[2025-01-07 00:00:00Z]
      now = ~U[2025-01-10 12:00:00Z]

      value_start = Engine.value_at(dataset, window_start, "EUR")
      value_now = Engine.value_at(dataset, now, "EUR")
      net_cashflow = Engine.net_cashflow(dataset, window_start, now, "EUR")

      assert_decimal(value_start, "220")
      assert_decimal(value_now, "420")
      assert_decimal(net_cashflow, "130")
      # Change: 420 - 220 - 130 = 70 actual performance, not 200.
      assert_decimal(value_now |> Decimal.sub(value_start) |> Decimal.sub(net_cashflow), "70")
    end

    test "transactions at the exact window boundary are excluded; at now they count" do
      dataset =
        eur_dataset([
          buy(1, ~U[2025-01-07 00:00:00Z], "2", "100"),
          buy(1, ~U[2025-01-10 12:00:00Z], "1", "130")
        ])

      net =
        Engine.net_cashflow(dataset, ~U[2025-01-07 00:00:00Z], ~U[2025-01-10 12:00:00Z], "EUR")

      assert_decimal(net, "130")
    end
  end

  describe "currency conversion" do
    test "a USD asset viewed in USD ignores FX" do
      dataset = usd_dataset([buy(2, ~U[2025-01-06 10:00:00Z], "4", "50", currency: "USD")])

      assert_decimal(Engine.value_at(dataset, ~U[2025-01-07 12:00:00Z], "USD"), "240")
    end

    test "a USD asset viewed in EUR converts per timestamp" do
      dataset = usd_dataset([buy(2, ~U[2025-01-06 10:00:00Z], "4", "50", currency: "USD")])

      # 2025-01-06: 200 USD / 1.25 = 160 EUR.
      assert_decimal(Engine.value_at(dataset, ~U[2025-01-06 12:00:00Z], "EUR"), "160")
      # 2025-01-07: 240 USD / 1.10 = 218.18...; compare via the same division.
      expected = Decimal.div(d("240"), d("1.10"))
      assert Decimal.eq?(Engine.value_at(dataset, ~U[2025-01-07 12:00:00Z], "EUR"), expected)
    end

    test "cost basis locks the txn conversion at execution and floats only base to display" do
      dataset = usd_dataset([buy(2, ~U[2025-01-06 10:00:00Z], "4", "50", currency: "USD")])

      # Locked at execution: 200 USD / 1.25 = 160 EUR, stable across days.
      assert_decimal(Engine.cost_basis_at(dataset, ~U[2025-01-06 12:00:00Z], "EUR"), "160")
      assert_decimal(Engine.cost_basis_at(dataset, ~U[2025-01-07 12:00:00Z], "EUR"), "160")
      # Viewed in USD it floats with the rate at t: 160 * 1.10 = 176.
      assert_decimal(Engine.cost_basis_at(dataset, ~U[2025-01-07 12:00:00Z], "USD"), "176")
    end

    test "an FX gap uses the latest earlier rate; before the first rate the oldest applies" do
      dataset = usd_dataset([buy(2, ~U[2025-01-05 10:00:00Z], "4", "50", currency: "USD")])

      # Executed before the first known rate (2025-01-06): oldest rate 1.25 applies.
      assert_decimal(Engine.cost_basis_at(dataset, ~U[2025-01-06 12:00:00Z], "EUR"), "160")

      # Saturday 2025-01-11: no rate after 01-07, so 1.10 still applies.
      expected = Decimal.div(d("240"), d("1.10"))
      assert Decimal.eq?(Engine.value_at(dataset, ~U[2025-01-11 12:00:00Z], "EUR"), expected)
    end

    test "an entirely unknown currency contributes zero rather than crashing" do
      dataset = %{
        usd_dataset([buy(2, ~U[2025-01-06 10:00:00Z], "4", "50", currency: "USD")])
        | fx: %{}
      }

      assert_decimal(Engine.value_at(dataset, ~U[2025-01-07 12:00:00Z], "EUR"), "0")
    end
  end

  describe "series" do
    test "value_series and profit_series sample every grid point" do
      dataset = eur_dataset([buy(1, ~U[2025-01-06 10:00:00Z], "1", "100")])
      grid = [~U[2025-01-07 00:00:00Z], ~U[2025-01-08 00:00:00Z], ~U[2025-01-09 00:00:00Z]]

      values = Engine.value_series(dataset, grid, "EUR")
      assert Enum.map(values, & &1.at) == grid
      assert_decimal(Enum.at(values, 0).value, "110")
      assert_decimal(Enum.at(values, 2).value, "130")

      profits = Engine.profit_series(dataset, grid, "EUR")
      assert_decimal(Enum.at(profits, 0).value, "10")
      assert_decimal(Enum.at(profits, 2).value, "30")
    end
  end
end
