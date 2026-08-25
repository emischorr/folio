defmodule FolioWeb.FormatTest do
  use ExUnit.Case, async: true

  alias FolioWeb.Format

  test "money groups thousands, rounds to two decimals, and prefixes the symbol" do
    assert Format.money(Decimal.new("24318.516"), "EUR") == "€ 24,318.52"
    assert Format.money(Decimal.new("5"), "USD") == "$ 5.00"
    assert Format.money(Decimal.new("1234567.8"), "EUR") == "€ 1,234,567.80"
    assert Format.money(Decimal.new("-30.11"), "EUR") == "−€ 30.11"
    assert Format.money(Decimal.new("100"), "CHF") == "CHF 100.00"
  end

  test "money_abs drops the sign" do
    assert Format.money_abs(Decimal.new("-30.11"), "EUR") == "€ 30.11"
  end

  test "percent renders one signed decimal and passes nil through" do
    assert Format.percent(Decimal.new("2.44")) == "+2.4 %"
    assert Format.percent(Decimal.new("-1.06")) == "−1.1 %"
    assert Format.percent(Decimal.new("40")) == "+40.0 %"
    assert Format.percent(nil) == nil
  end

  test "quantity trims trailing zeros and caps at eight decimals" do
    assert Format.quantity(Decimal.new("0.14200000")) == "0.142"
    assert Format.quantity(Decimal.new("15")) == "15"
    assert Format.quantity(Decimal.new("78.50")) == "78.5"
    assert Format.quantity(Decimal.new("0.123456789")) == "0.12345679"
  end
end
